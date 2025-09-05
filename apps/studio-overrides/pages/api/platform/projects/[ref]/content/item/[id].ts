import { fetchPost } from 'data/fetchers'
import { constructHeaders } from 'lib/api/apiHelpers'
import apiWrapper from 'lib/api/apiWrapper'
import { PG_META_URL } from 'lib/constants'
import { NextApiRequest, NextApiResponse } from 'next'
import { paths } from 'api-types'

export default (req: NextApiRequest, res: NextApiResponse) => apiWrapper(req, res, handler)

const escapeSql = (val: any) => {
  if (val === undefined || val === null) return 'NULL'
  if (typeof val === 'number') return val;
  return `'${String(val).replace(/'/g, "''")}'`
}

async function handler(req: NextApiRequest, res: NextApiResponse) {
  const { method } = req

  switch (method) {
    case 'GET':
      return handleGet(req, res)
    default:
      res.setHeader('Allow', ['GET'])
      res.status(405).json({ error: { message: `Method ${method} Not Allowed` } })
  }
}

type ResponseData =
  paths['/platform/projects/{ref}/content/item/{id}']['get']['responses']['200']['content']['application/json']

const handleGet = async (req: NextApiRequest, res: NextApiResponse<ResponseData>) => {
  // We only need the 'id' from the query parameters
  const { id } = req.query
  const headers = constructHeaders(req.headers)

  // FIXED: Query for a single snippet by its unique ID only.
  // The UUID is unique enough that we don't need to check the project_id.
  const query = `
    SELECT id, name, description, visibility, content, owner_id, project_id, inserted_at, updated_at
    FROM studio.sql_snippets
    WHERE id = ${escapeSql(id as string)};
  `

  const response = await fetchPost(`${PG_META_URL}/query`, { query }, { headers })

  if (response.error) {
    console.error("Error in content/item/id:", response.error)
    const errorMessage = response.error.message || 'An unknown error occurred'
    return res.status(400).json({ error: { message: errorMessage } })
  }

  const snippet = response?.[0]

  if (!snippet) {
    return res.status(404).json({ error: { message: `Content with id ${id} not found` } })
  }

  const formattedSnippet = {
    ...snippet,
    content: {
      content_id: snippet.id,
      sql: snippet.content,
      schema_version: '1',
      favorite: false,
    },
  }

  return res.status(200).json(formattedSnippet)
}