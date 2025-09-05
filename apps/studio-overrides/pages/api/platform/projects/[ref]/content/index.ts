import { fetchPost } from 'data/fetchers'
import { constructHeaders } from 'lib/api/apiHelpers'
import apiWrapper from 'lib/api/apiWrapper'
import { PG_META_URL } from 'lib/constants'
import { NextApiRequest, NextApiResponse } from 'next'

// We no longer need Supabase auth for this endpoint.
export default (req: NextApiRequest, res: NextApiResponse) =>
  apiWrapper(req, res, handler)

const escapeSql = (val: any) => {
  if (val === undefined || val === null) return 'NULL'
  // Handle numbers separately from strings
  if (typeof val === 'number') return val;
  // Escape strings
  return `'${String(val).replace(/'/g, "''")}'`
}

async function handler(req: NextApiRequest, res: NextApiResponse) {
  const { method } = req

  switch (method) {
    case 'GET':
      return handleGetAll(req, res)
    case 'PUT':
      return handlePut(req, res)
    default:
      res.setHeader('Allow', ['GET', 'PUT'])
      res.status(405).json({ data: null, error: { message: `Method ${method} Not Allowed` } })
  }
}

const handleGetAll = async (req: NextApiRequest, res: NextApiResponse) => {
  const { ref } = req.query
  const headers = constructHeaders(req.headers)
  
  // Get all snippets for the project, since we are not filtering by user anymore.
  const query = `
    SELECT id, name, description, visibility, content, owner_id, project_id, inserted_at, updated_at 
    FROM studio.sql_snippets 
    WHERE project_id = ${escapeSql(ref as string)}
    ORDER BY updated_at DESC;
  `
  
  const response = await fetchPost(`${PG_META_URL}/query`, { query }, { headers })

  if (response.error) {
    console.error("Error in handleGetAll:", response.error);
    const errorMessage = response.error.message || 'An unknown error occurred';
    return res.status(400).json({ error: { message: errorMessage } });
  }

  const formattedData = response.map((snippet: any) => ({
    ...snippet,
    content: {
      content_id: snippet.id,
      sql: snippet.content,
      schema_version: '1.0',
      favorite: false,
    },
  }))

  return res.status(200).json({ data: formattedData })
}

const handlePut = async (req: NextApiRequest, res: NextApiResponse) => {
  const snippet = req.body
  const headers = constructHeaders(req.headers)

  // Use an UPSERT command (INSERT ... ON CONFLICT ... DO UPDATE).
  // It now uses the owner_id and project_id from the request body.
  const query = `
    INSERT INTO studio.sql_snippets (id, project_id, owner_id, name, description, visibility, content)
    VALUES (
      ${escapeSql(snippet.id)},
      ${escapeSql(snippet.project_id)},
      ${escapeSql(snippet.owner_id)},
      ${escapeSql(snippet.name)},
      ${escapeSql(snippet.description)},
      ${escapeSql(snippet.visibility)},
      ${escapeSql(snippet.content?.sql)}
    )
    ON CONFLICT (id) DO UPDATE SET
      name = EXCLUDED.name,
      description = EXCLUDED.description,
      content = EXCLUDED.content,
      updated_at = NOW()
    RETURNING *;
  `

  const response = await fetchPost(`${PG_META_URL}/query`, { query }, { headers })

  if (response.error) {
    console.error("Error in handlePut:", response.error);
    const errorMessage = response.error.message || 'An unknown error occurred';
    return res.status(400).json({ error: { message: errorMessage } });
  }

  const responseData = response?.[0]

  if (responseData) {
    responseData.content = {
      content_id: responseData.id,
      sql: responseData.content,
      schema_version: '1.0',
      favorite: false,
    }
  }

  return res.status(200).json({ data: responseData })
}