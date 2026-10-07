-- Demo setup for the fictional Maple Grove Dental Studio:
-- patients only see the patient handbook; staff see both handbooks.

SET search_path TO knowledge, public;

INSERT INTO knowledge_bases (slug, name, description) VALUES
  ('patient-handbook', 'Patient handbook',
   'Aftercare instructions, insurance and payments, cancellation policy, new patient FAQ, emergencies.'),
  ('staff-handbook', 'Staff handbook',
   'Internal policies: time off, shifts, sterilization protocol, onboarding.');

INSERT INTO agents (slug, name) VALUES
  ('patient-assistant', 'Patient assistant'),
  ('staff-assistant', 'Staff assistant');

INSERT INTO agent_knowledge_bases (agent_id, knowledge_base_id)
SELECT a.id, kb.id
FROM agents a
JOIN knowledge_bases kb ON (a.slug, kb.slug) IN (
  ('patient-assistant', 'patient-handbook'),
  ('staff-assistant', 'patient-handbook'),
  ('staff-assistant', 'staff-handbook'));
