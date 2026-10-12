// Removes instance-specific data from exported workflows so they can be committed.
// Runs inside the n8n container: node /repo/scripts/clean-export.js
const fs = require('fs');
const path = require('path');

const DIR = '/repo/workflows';
// Fields that describe this instance (owner, versions, timestamps), not the workflow itself
const DROP = ['shared', 'versionMetadata', 'activeVersionId', 'versionCounter', 'triggerCount',
  'sourceWorkflowId', 'createdAt', 'updatedAt', 'versionId', 'staticData', 'pinData', 'isArchived'];

for (const file of fs.readdirSync(DIR).filter(f => f.endsWith('.json'))) {
  const full = path.join(DIR, file);
  let workflow = JSON.parse(fs.readFileSync(full, 'utf8'));
  if (Array.isArray(workflow)) workflow = workflow[0];

  for (const field of DROP) delete workflow[field];
  if (workflow.meta) delete workflow.meta.instanceId;
  workflow.active = false;

  fs.writeFileSync(full, JSON.stringify(workflow, null, 2) + '\n');
  console.log(`cleaned ${file}`);
}
