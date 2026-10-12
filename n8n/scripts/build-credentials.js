// Builds the n8n credentials file from environment variables, for `n8n import:credentials`.
// The ids match the ones referenced by the workflows, so nodes are linked without manual selection.
// Runs inside the n8n container: node /repo/scripts/build-credentials.js
const fs = require('fs');

const env = process.env;
const OUTPUT = '/tmp/credentials-to-import.json';

// The service account key file is read on the host by setup-n8n.sh and passed as JSON text
function serviceAccount() {
  const key = JSON.parse(env.GOOGLE_SERVICE_ACCOUNT_JSON);
  if (key.type !== 'service_account') throw new Error('GOOGLE_SERVICE_ACCOUNT_KEY_FILE is not a service account key');
  return key;
}

const credentials = [
  {
    id: 'pG7rT2kW9mQ4xL1z',
    name: 'Postgres rag_app',
    type: 'postgres',
    // rag_app, not the owner: row level security applies to everything n8n does
    required: ['POSTGRES_DB', 'RAG_APP_PASSWORD'],
    data: () => ({ host: 'postgres', port: 5432, database: env.POSTGRES_DB, user: 'rag_app', password: env.RAG_APP_PASSWORD }),
  },
  {
    id: 'dR5sA8vN3jK6hY2b',
    name: 'Google Drive service account',
    type: 'googleApi',
    required: ['GOOGLE_SERVICE_ACCOUNT_JSON'],
    data: () => ({
      email: serviceAccount().client_email,
      privateKey: serviceAccount().private_key,
      // Used from HTTP Request nodes, read-only
      httpNode: true,
      scopes: 'https://www.googleapis.com/auth/drive.readonly',
    }),
  },
  {
    id: 'gM4nK7pQ1wE9rT6y',
    name: 'Google Gemini(PaLM) Api account',
    type: 'googlePalmApi',
    required: ['GEMINI_API_KEY'],
    data: () => ({ host: 'https://generativelanguage.googleapis.com', apiKey: env.GEMINI_API_KEY }),
  },
  {
    id: 'iA2pK5eY8uR3tW6q',
    name: 'Ingest API key',
    type: 'httpHeaderAuth',
    required: ['INGEST_API_KEY'],
    data: () => ({ name: 'X-API-Key', value: env.INGEST_API_KEY }),
  },
];

const ready = [];
for (const credential of credentials) {
  const missing = credential.required.filter(name => !env[name]);
  if (missing.length) {
    console.warn(`skipped "${credential.name}": missing ${missing.join(', ')} in .env`);
    continue;
  }
  ready.push({ id: credential.id, name: credential.name, type: credential.type, data: credential.data() });
  console.log(`prepared "${credential.name}"`);
}

fs.writeFileSync(OUTPUT, JSON.stringify(ready), { mode: 0o600 });
