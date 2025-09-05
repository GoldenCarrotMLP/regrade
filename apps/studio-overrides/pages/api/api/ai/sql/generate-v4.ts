import pgMeta from '@supabase/pg-meta'
import { convertToModelMessages, ModelMessage, stepCountIs, streamText } from 'ai'
import { source } from 'common-tags'
import { NextApiRequest, NextApiResponse } from 'next'
import { z } from 'zod/v4'

import { IS_PLATFORM } from 'common'
import { executeSql } from 'data/sql/execute-sql-query'
import { AiOptInLevel } from 'hooks/misc/useOrgOptedIntoAi'
import { getModel } from 'lib/ai/model'
import { getOrgAIDetails } from 'lib/ai/org-ai-details'
import { getTools } from 'lib/ai/tools'
import apiWrapper from 'lib/api/apiWrapper'
import { queryPgMetaSelfHosted } from 'lib/self-hosted'

import {
  CHAT_PROMPT,
  EDGE_FUNCTION_PROMPT,
  GENERAL_PROMPT,
  PG_BEST_PRACTICES,
  RLS_PROMPT,
  SECURITY_PROMPT,
} from 'lib/ai/prompts'

export const maxDuration = 120

export const config = {
  api: { bodyParser: true },
}

async function handler(req: NextApiRequest, res: NextApiResponse) {
  const { method } = req
  if (method !== 'POST') {
    res.setHeader('Allow', ['POST'])
    return res.status(405).json({ data: null, error: { message: `Method ${method} Not Allowed` } })
  }

  const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body
  const { data, error: parseError } = requestBodySchema.safeParse(body)

  if (parseError) {
    return res.status(400).json({ error: 'Invalid request body', issues: parseError.issues })
  }

  const { messages: rawMessages, projectRef, connectionString, orgSlug, chatName } = data

  const messages = (rawMessages || []).slice(-7).map((msg: any) => {
    if (msg?.role === 'assistant' && 'results' in msg) {
      const { results, ...rest } = msg
      return rest
    }
    if (msg?.role === 'assistant' && msg.parts) {
      const cleanedParts = msg.parts.filter(
        (part: any) => !(part.type.startsWith('tool-') && part.state === 'input-streaming')
      )
      return { ...msg, parts: cleanedParts }
    }
    return msg
  })

  let aiOptInLevel: AiOptInLevel = 'schema' // Self-hosted default
  let isLimited = false
  const authorization = req.headers.authorization

  // Cloud Platform specific logic
  if (IS_PLATFORM) {
    const accessToken = authorization?.replace('Bearer ', '')
    if (!accessToken) {
      return res.status(401).json({ message: 'Invalid authentication credentials' })
    }

    if (orgSlug && authorization && projectRef) {
      try {
        const { aiOptInLevel: orgAIOptInLevel, isLimited: orgAILimited } = await getOrgAIDetails({
          orgSlug,
          authorization,
          projectRef,
        })
        aiOptInLevel = orgAIOptInLevel
        isLimited = orgAILimited
      } catch (error) {
        return res.status(400).json({ error: 'There was an error fetching your organization details' })
      }
    }
  }

  const { model, error: modelError } = await getModel(projectRef, isLimited)
  if (modelError) {
    return res.status(500).json({ error: modelError.message })
  }

  try {
    const pgMetaSchemasList = pgMeta.schemas.list()
    const { result: schemas } =
      aiOptInLevel !== 'disabled'
        ? await executeSql(
            { projectRef, connectionString, sql: pgMetaSchemasList.sql },
            undefined,
            {
              'Content-Type': 'application/json',
              ...(authorization && { Authorization: authorization }),
            },
            IS_PLATFORM ? undefined : queryPgMetaSelfHosted
          )
        : { result: [] }

    const schemasString =
      schemas?.length > 0
        ? `The available database schema names are: ${JSON.stringify(schemas)}`
        : "You don't have access to any schemas."

    const system = source`
      ${GENERAL_PROMPT}
      ${CHAT_PROMPT}
      ${PG_BEST_PRACTICES}
      ${RLS_PROMPT}
      ${EDGE_FUNCTION_PROMPT}
      ${SECURITY_PROMPT}
    `
    const coreMessages: ModelMessage[] = [
      {
        role: 'system',
        content: system,
        providerOptions: { bedrock: { cachePoint: { type: 'default' } } },
      },
      {
        role: 'assistant',
        content: `The user's current project is ${projectRef}. Their available schemas are: ${schemasString}. The current chat name is: ${chatName}`,
      },
      ...convertToModelMessages(messages),
    ]

    const abortController = new AbortController()
    req.on('close', () => abortController.abort())
    req.on('aborted', () => abortController.abort())

    const tools = await getTools({
      projectRef,
      connectionString,
      authorization,
      aiOptInLevel,
      accessToken: IS_PLATFORM ? authorization?.replace('Bearer ', '') : undefined,
    })

    const result = streamText({
      model,
      stopWhen: stepCountIs(5),
      messages: coreMessages,
      tools,
      abortSignal: abortController.signal,
    })

    result.pipeUIMessageStreamToResponse(res)
  } catch (error) {
    console.error('Error in handlePost:', error)
    if (error instanceof Error) {
      return res.status(500).json({ message: error.message })
    }
    return res.status(500).json({ message: 'An unexpected error occurred.' })
  }
}

const requestBodySchema = z.object({
  messages: z.array(z.any()),
  projectRef: z.string(),
  connectionString: z.string(),
  schema: z.string().optional(),
  table: z.string().optional(),
  chatName: z.string().optional(),
  orgSlug: z.string().optional(),
})

// The regular wrapper is sufficient now that the frontend is fixed.
const wrapper = (req: NextApiRequest, res: NextApiResponse) =>
  apiWrapper(req, res, handler, { withAuth: true })

export default wrapper