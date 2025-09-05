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
      return handleGetAll(req, res)
    case 'POST':
      return handlePost(req, res)
    case 'DELETE':
      return handleDelete(req, res)
    default:
      res.setHeader('Allow', ['GET', 'POST', 'DELETE'])
      res.status(405).json({ data: null, error: { message: `Method ${method} Not Allowed` } })
  }
}

type GetResponseData =
  paths['/platform/projects/{ref}/content/folders']['get']['responses']['200']['content']['application/json']

const handleGetAll = async (req: NextApiRequest, res: NextApiResponse<GetResponseData>) => {
  const { sort_by, sort_order } = req.query
  const headers = constructHeaders(req.headers)

  const allowedSortColumns = ['inserted_at', 'updated_at', 'name']
  const allowedSortOrders = ['asc', 'desc']

  const sortByColumn = allowedSortColumns.includes(sort_by as string) ? sort_by : 'updated_at'
  const sortOrderDirection = allowedSortOrders.includes(sort_order as string) ? sort_order : 'desc'

  // FIXED: Removed the "WHERE project_id = ..." clause to fetch all snippets,
  // resolving the 'default' vs 1 mismatch.
  const query = `
    SELECT id, name, description, visibility, owner_id, project_id, inserted_at, updated_at
    FROM studio.sql_snippets
    ORDER BY ${sortByColumn} ${sortOrderDirection};
  `
  
  const response = await fetchPost(`${PG_META_URL}/query`, { query }, { headers })

  if (response.error) {
    console.error("Error in content/folders:", response.error)
    const errorMessage = response.error.message || 'An unknown error occurred'
    return res.status(400).json({ data: null, error: { message: errorMessage } })
  }

  const formattedContents = response.map((snippet: any) => ({
    ...snippet,
    type: 'sql',
    favorite: false,
    owner: {
      id: snippet.owner_id,
      username: 'default_user',
    },
    updated_by: {
      id: snippet.owner_id,
      username: 'default_user',
    }
  }));

  return res.status(200).json({
    data: {
      folders: [],
      contents: formattedContents,
    },
  })
}

const handlePost = async (req: NextApiRequest, res: NextApiResponse) => {
  return res.status(200).json({})
}

const handleDelete = async (req: NextApiRequest, res: NextApiResponse) => {
  return res.status(200).json({})
}