//functions/passkey-auth/index.ts
import { serve } from 'https://deno.land/std@0.208.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.0';
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from 'npm:@simplewebauthn/server@11.0.0';

interface RequestBody {
  endpoint: string;
  data: Record<string, unknown>;
}

interface ApiResponse<T = unknown> {
  success: boolean;
  data?: T;
  error?: { code: string; message: string };
}

const CHALLENGE_TTL_MINUTES = 5;
const SUPPORTED_ALGORITHMS = [-7, -257];
const RATE_LIMITS = { ip: { maxAttempts: 5, windowMinutes: 1 }, email: { maxAttempts: 10, windowMinutes: 1 } };

function success<T>(data: T): ApiResponse<T> {
  return { success: true, data };
}

function error(code: string, message: string): ApiResponse {
  return { success: false, error: { code, message } };
}

function getOrigin(request: Request): string {
  const origin = request.headers.get('origin');
  if (origin) return origin;
  const url = new URL(request.url);
  return `${url.protocol}//${url.host}`;
}

function getClientIP(request: Request): string {
  return request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ||
    request.headers.get('x-real-ip') ||
    request.headers.get('cf-connecting-ip') ||
    '0.0.0.0';
}

function uint8ArrayToBase64Url(bytes: Uint8Array): string {
  const base64 = btoa(String.fromCharCode(...bytes));
  return base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function uint8ArrayToHex(bytes: Uint8Array): string {
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, '0')).join('');
}

function hexToUint8Array(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = Number.parseInt(hex.substring(i, i + 2), 16);
  }
  return bytes;
}

function generateWebAuthnUserId(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return uint8ArrayToBase64Url(bytes);
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization, apikey, x-client-info',
      },
    });
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const supabaseAdmin = createClient(supabaseUrl, supabaseServiceKey);
  const origin = getOrigin(req);
  const clientIP = getClientIP(req);

  try {
    const { endpoint, data }: RequestBody = await req.json();
    const { rpId, rpName, email, challengeId, response: authResponse } = data as Record<string, unknown>;

    let result: ApiResponse;

    switch (endpoint) {
      case '/register/start': {
        const ipBlocked = await supabaseAdmin.rpc('check_passkey_rate_limit', {
          p_identifier: clientIP, p_identifier_type: 'ip', p_endpoint: endpoint, p_max_attempts: RATE_LIMITS.ip.maxAttempts
        });
        if (ipBlocked.error || ipBlocked.data) {
          result = error('RATE_LIMITED', 'Too many requests');
          break;
        }

        const webauthnUserId = generateWebAuthnUserId();
        const { data: existingUser } = await supabaseAdmin.from('passkey_credentials')
          .select('id').eq('webauthn_user_id', webauthnUserId).limit(1);

        const excludeCredentials = existingUser?.map((c: { id: string }) => ({
          id: c.id, type: 'public-key' as const
        })) || [];

        const options = await generateRegistrationOptions({
          rpName: rpName as string,
          rpID: rpId as string,
          userName: email as string,
          userDisplayName: email as string,
          userID: new TextEncoder().encode(webauthnUserId),
          attestationType: 'none',
          excludeCredentials,
          authenticatorSelection: { residentKey: 'preferred', userVerification: 'preferred' },
          supportedAlgorithmIDs: SUPPORTED_ALGORITHMS,
        });

        const expiresAt = new Date(Date.now() + CHALLENGE_TTL_MINUTES * 60 * 1000);
        const { data: challenge } = await supabaseAdmin.from('passkey_challenges').insert({
          challenge: options.challenge, email, type: 'registration', expires_at: expiresAt.toISOString(), webauthn_user_id: webauthnUserId
        }).select().single();

        await supabaseAdmin.rpc('log_passkey_audit_event', {
          p_event_type: 'registration_started', p_email: email, p_ip_address: clientIP, p_origin: origin
        });

        result = success({ options, challengeId: challenge.id });
        break;
      }

      case '/register/finish': {
        const { data: challenge } = await supabaseAdmin.from('passkey_challenges')
          .select('*').eq('id', challengeId).eq('type', 'registration').single();

        await supabaseAdmin.from('passkey_challenges').delete().eq('id', challengeId);

        if (!challenge) {
          result = error('CHALLENGE_MISMATCH', 'Invalid or expired challenge');
          break;
        }

        if (new Date(challenge.expires_at) < new Date()) {
          await supabaseAdmin.rpc('log_passkey_audit_event', {
            p_event_type: 'challenge_expired', p_email: challenge.email, p_ip_address: clientIP
          });
          result = error('CHALLENGE_EXPIRED', 'Challenge has expired');
          break;
        }

        try {
          const verification = await verifyRegistrationResponse({
            response: authResponse as Parameters<typeof verifyRegistrationResponse>[0]['response'],
            expectedChallenge: challenge.challenge,
            expectedOrigin: origin,
            expectedRPID: rpId as string,
            supportedAlgorithmIDs: SUPPORTED_ALGORITHMS,
          });

          if (!verification.verified || !verification.registrationInfo) {
            throw new Error('Verification failed');
          }

          const { credential, credentialDeviceType, credentialBackedUp } = verification.registrationInfo;
          const publicKeyBytes = credential.publicKey;
          const publicKeyHex = '\\x' + uint8ArrayToHex(publicKeyBytes);

          let userId: string;
          const { data: existingUsers } = await supabaseAdmin.auth.admin.listUsers();
          const existingUser = existingUsers?.users?.find((u) => u.email === challenge.email);

          if (existingUser) {
            userId = existingUser.id;
          } else {
            const { data: newUser } = await supabaseAdmin.auth.admin.createUser({
              email: challenge.email, email_confirm: true
            });
            userId = newUser.user!.id;
          }

          const authenticatorName = (data as { authenticatorName?: string }).authenticatorName || null;

          const { data: insertedCred } = await supabaseAdmin.from('passkey_credentials').insert({
            id: credential.id,
            user_id: userId,
            webauthn_user_id: challenge.webauthn_user_id,
            public_key: publicKeyHex,
            counter: credential.counter,
            device_type: credentialDeviceType,
            backed_up: credentialBackedUp,
            transports: credential.transports,
            authenticator_name: authenticatorName,
          }).select().single();

          const { data: linkData } = await supabaseAdmin.auth.admin.generateLink({
            type: 'magiclink', email: challenge.email
          });

          await supabaseAdmin.rpc('log_passkey_audit_event', {
            p_event_type: 'registration_completed', p_user_id: userId, p_credential_id: credential.id, p_email: challenge.email, p_ip_address: clientIP
          });

          result = success({
            verified: true,
            tokenHash: linkData.properties?.hashed_token,
            passkey: insertedCred ? {
              id: insertedCred.id,
              authenticatorName: insertedCred.authenticator_name,
              deviceType: insertedCred.device_type,
              backedUp: insertedCred.backed_up,
              createdAt: insertedCred.created_at,
              lastUsedAt: insertedCred.last_used_at,
            } : null
          });
        } catch (e) {
          await supabaseAdmin.rpc('log_passkey_audit_event', {
            p_event_type: 'registration_failed', p_email: challenge.email, p_ip_address: clientIP, p_error_message: e instanceof Error ? e.message : 'Unknown'
          });
          result = error('VERIFICATION_FAILED', 'Registration verification failed');
        }
        break;
      }

      case '/login/start': {
        const ipBlocked = await supabaseAdmin.rpc('check_passkey_rate_limit', {
          p_identifier: clientIP, p_identifier_type: 'ip', p_endpoint: endpoint, p_max_attempts: RATE_LIMITS.ip.maxAttempts
        });
        if (ipBlocked.error || ipBlocked.data) {
          result = error('RATE_LIMITED', 'Too many requests');
          break;
        }

        let allowCredentials: { id: string; type: 'public-key' }[] | undefined;
        let userEmail = email as string | undefined;

        if (email) {
          const { data: users } = await supabaseAdmin.auth.admin.listUsers();
          const user = users?.users?.find((u) => u.email === email);
          if (!user) {
            result = error('CREDENTIAL_NOT_FOUND', 'No passkey found for this email');
            break;
          }

          const { data: credentials } = await supabaseAdmin.from('passkey_credentials')
            .select('id, transports').eq('user_id', user.id);

          if (!credentials?.length) {
            result = error('CREDENTIAL_NOT_FOUND', 'No passkey found for this email');
            break;
          }

          allowCredentials = credentials.map((c) => ({ id: c.id, type: 'public-key' as const }));
        }

        const options = await generateAuthenticationOptions({
          rpID: rpId as string,
          userVerification: 'preferred',
          allowCredentials,
        });

        const expiresAt = new Date(Date.now() + CHALLENGE_TTL_MINUTES * 60 * 1000);
        const { data: challenge } = await supabaseAdmin.from('passkey_challenges').insert({
          challenge: options.challenge, email: userEmail, type: 'authentication', expires_at: expiresAt.toISOString()
        }).select().single();

        await supabaseAdmin.rpc('log_passkey_audit_event', {
          p_event_type: 'authentication_started', p_email: userEmail, p_ip_address: clientIP
        });

        result = success({ options, challengeId: challenge.id });
        break;
      }

      case '/login/finish': {
        const { data: challenge } = await supabaseAdmin.from('passkey_challenges')
          .select('*').eq('id', challengeId).eq('type', 'authentication').single();

        await supabaseAdmin.from('passkey_challenges').delete().eq('id', challengeId);

        if (!challenge) {
          result = error('CHALLENGE_MISMATCH', 'Invalid or expired challenge');
          break;
        }

        if (new Date(challenge.expires_at) < new Date()) {
          result = error('CHALLENGE_EXPIRED', 'Challenge has expired');
          break;
        }

        const credentialId = (authResponse as { id: string }).id;
        const { data: credential, error: credError } = await supabaseAdmin.from('passkey_credentials')
          .select('*').eq('id', credentialId).single();

        if (credError || !credential) {
          result = error('CREDENTIAL_NOT_FOUND', 'Credential not found');
          break;
        }

        try {
          const publicKeyHex = credential.public_key.replace('\\x', '');
          const publicKeyBytes = hexToUint8Array(publicKeyHex);

          const verification = await verifyAuthenticationResponse({
            response: authResponse as Parameters<typeof verifyAuthenticationResponse>[0]['response'],
            expectedChallenge: challenge.challenge,
            expectedOrigin: origin,
            expectedRPID: rpId as string,
            credential: {
              id: credential.id,
              publicKey: publicKeyBytes,
              counter: credential.counter,
            },
          });

          if (!verification.verified) {
            throw new Error('Verification failed');
          }

          await supabaseAdmin.from('passkey_credentials').update({
            counter: verification.authenticationInfo.newCounter, last_used_at: new Date().toISOString()
          }).eq('id', credentialId);

          const { data: userData } = await supabaseAdmin.auth.admin.getUserById(credential.user_id);
          const userEmail = userData?.user?.email || challenge.email;
          const { data: linkData } = await supabaseAdmin.auth.admin.generateLink({
            type: 'magiclink', email: userEmail
          });

          await supabaseAdmin.rpc('log_passkey_audit_event', {
            p_event_type: 'authentication_completed', p_user_id: credential.user_id, p_credential_id: credentialId, p_ip_address: clientIP
          });

          result = success({ verified: true, tokenHash: linkData.properties?.hashed_token, email: userEmail });
        } catch (e) {
          await supabaseAdmin.rpc('log_passkey_audit_event', {
            p_event_type: 'authentication_failed', p_credential_id: credentialId, p_ip_address: clientIP, p_error_message: e instanceof Error ? e.message : 'Unknown'
          });
          result = error('VERIFICATION_FAILED', 'Authentication verification failed');
        }
        break;
      }

      case '/passkeys/list': {
        const authHeader = req.headers.get('Authorization');
        const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
        const userClient = createClient(supabaseUrl, supabaseAnonKey, {
          global: { headers: { Authorization: authHeader || '' } }
        });
        const { data: { user } } = await userClient.auth.getUser();

        if (!user) {
          result = error('UNAUTHORIZED', 'Authentication required');
          break;
        }

        const { data: credentials } = await supabaseAdmin.from('passkey_credentials')
          .select('*').eq('user_id', user.id).order('created_at', { ascending: false });

        result = success({
          passkeys: credentials?.map((c) => ({
            id: c.id, authenticatorName: c.authenticator_name, deviceType: c.device_type,
            backedUp: c.backed_up, createdAt: c.created_at, lastUsedAt: c.last_used_at
          })) || []
        });
        break;
      }

      case '/passkeys/remove': {
        const authHeader = req.headers.get('Authorization');
        const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
        const userClient = createClient(supabaseUrl, supabaseAnonKey, {
          global: { headers: { Authorization: authHeader || '' } }
        });
        const { data: { user } } = await userClient.auth.getUser();

        if (!user) {
          result = error('UNAUTHORIZED', 'Authentication required');
          break;
        }

        const { credentialId: removeCredId } = data as { credentialId: string };
        await supabaseAdmin.from('passkey_credentials').delete().eq('id', removeCredId).eq('user_id', user.id);

        await supabaseAdmin.rpc('log_passkey_audit_event', {
          p_event_type: 'passkey_removed', p_user_id: user.id, p_credential_id: removeCredId, p_ip_address: clientIP
        });

        result = success({ removed: true });
        break;
      }

      case '/passkeys/update': {
        const authHeader = req.headers.get('Authorization');
        const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
        const userClient = createClient(supabaseUrl, supabaseAnonKey, {
          global: { headers: { Authorization: authHeader || '' } }
        });
        const { data: { user } } = await userClient.auth.getUser();

        if (!user) {
          result = error('UNAUTHORIZED', 'Authentication required');
          break;
        }

        const { credentialId: updateCredId, authenticatorName } = data as { credentialId: string; authenticatorName: string };
        const { data: updated } = await supabaseAdmin.from('passkey_credentials')
          .update({ authenticator_name: authenticatorName }).eq('id', updateCredId).eq('user_id', user.id).select().single();

        if (!updated) {
          result = error('CREDENTIAL_NOT_FOUND', 'Passkey not found');
          break;
        }

        await supabaseAdmin.rpc('log_passkey_audit_event', {
          p_event_type: 'passkey_updated', p_user_id: user.id, p_credential_id: updateCredId, p_ip_address: clientIP
        });

        result = success({ passkey: updated });
        break;
      }

      default:
        result = error('NOT_FOUND', `Unknown endpoint: ${endpoint}`);
    }

    return new Response(JSON.stringify(result), {
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (e) {
    return new Response(JSON.stringify(error('UNKNOWN_ERROR', 'Internal server error')), {
      status: 500,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  }
});
