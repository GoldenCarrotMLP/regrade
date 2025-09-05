import { generateObject } from 'ai'
import { ContextLengthError } from 'ai-commands'
import { source } from 'common-tags'
import { getModel } from 'lib/ai/model'
import apiWrapper from 'lib/api/apiWrapper'
import { NextApiRequest, NextApiResponse } from 'next'
import { z } from 'zod'

async function handler(req: NextApiRequest, res: NextApiResponse) {
  const { model, error: modelError } = await getModel()

  if (modelError) {
    return res.status(500).json({ error: modelError.message })
  }

  const { method } = req

  switch (method) {
    case 'POST':
      return handlePost(req, res, model)
    default:
      res.setHeader('Allow', ['POST'])
      res.status(405).json({ data: null, error: { message: `Method ${method} Not Allowed` } })
  }
}

const classificationSchema = z.object({
  feedback_category: z
    .enum(['bug', 'feature_request', 'praise', 'other'])
    .describe('The category of the feedback.'),
})

export async function handlePost(req: NextApiRequest, res: NextApiResponse, model: any) {
  const {
    body: { prompt },
  } = req

  try {
    const { object: result } = await generateObject({
      model,
      schema: classificationSchema,
      prompt: source`
        You are a feedback classification expert. Classify the following user feedback into one of the available categories.
        
        User Feedback: "${prompt}"
      `,
    })

    res.status(200).json(result)
    return
  } catch (error) {
    if (error instanceof Error) {
      console.error(`AI feedback classification failed: ${error.message}`)

      if (error instanceof ContextLengthError || error.message.includes('context_length')) {
        return res.status(400).json({
          error:
            'Your feedback prompt is too large for Supabase AI to ingest. Try splitting it into smaller prompts.',
        })
      }
    } else {
      console.error(`Unknown error: ${error}`)
    }

    return res.status(500).json({
      error: 'There was an unknown error classifying the feedback. Please try again.',
    })
  }
}

const wrapper = (req: NextApiRequest, res: NextApiResponse) =>
  apiWrapper(req, res, handler, { withAuth: true })

export default wrapper