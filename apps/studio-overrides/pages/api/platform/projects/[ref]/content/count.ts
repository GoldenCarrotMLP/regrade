import { fetchPost } from 'data/fetchers'
import { constructHeaders } from 'lib/api/apiHelpers'
import apiWrapper from 'lib/api/apiWrapper'
import { PG_META_URL } from 'lib/constants'
import { NextApiRequest, NextApiResponse } from 'next'
import { paths } from 'api-types'

export default (req: NextApiRequest, res: NextApiResponse) => apiWrapper(req, res, handler)

async function handler(req: NextApiRequest, res: NextApiResponse) {
  const { method } = req

  switch (method) {
    case 'GET':
      return handleGet(req, res)
    default:
      res.setHeader('Allow', ['GET'])
      res.status(405).json({ data: null, error: { message: `Method ${method} Not Allowed` } })
  }
}

type ResponseData =
  paths['/platform/projects/{ref}/content/count']['get']['responses']['200']['content']['application/json']

const handleGet = async (req: NextApiRequest, res: NextApiResponse<ResponseData>) => {
  const headers = constructHeaders(req.headers)

  // FIXED: Removed the "WHERE project_id = ..." clause to count all snippets.
  const query = `SELECT COUNT(*) as count FROM studio.sql_snippets;`

  const response = await fetchPost(`${PG_META_URL}/query`, { query }, { headers })

  if (response.error) {
    console.error("Error in content/count:", response.error)
    const errorMessage = response.error.message || 'An unknown error occurred'
    return res.status(400).json({ shared: 0, favorites: 0, private: 0, error: { message: errorMessage } })
  }
  
  const count = response?.[0]?.count || 0

  return res.status(200).json({ shared: 0, favorites: 0, private: Number(count) })
}