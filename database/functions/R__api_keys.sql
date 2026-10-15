-- Search API keys. create_api_key and revoke_api_key are for the owner (scripts/create-api-key.sh);
-- rag_app, the role n8n uses, can only check a key.

SET search_path TO knowledge, public;

CREATE OR REPLACE FUNCTION api_key_hash(p_key text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = knowledge, public AS $$
  SELECT encode(sha256(convert_to(p_key, 'UTF8')), 'hex')
$$;


-- Returns the new key: it is the only time it can be seen
CREATE OR REPLACE FUNCTION create_api_key(p_agent text, p_label text) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = knowledge, public AS $$
DECLARE
  v_agent_id int;
  v_key      text;
BEGIN
  SELECT id INTO v_agent_id FROM agents WHERE slug = p_agent;
  IF v_agent_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Unknown agent.');
  END IF;
  IF coalesce(trim(p_label), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'A label is required (who uses this key).');
  END IF;

  -- 2 random UUIDs = 244 random bits
  v_key := 'rag_' || replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  INSERT INTO agent_api_keys (agent_id, label, key_hash, key_prefix)
  VALUES (v_agent_id, trim(p_label), api_key_hash(v_key), left(v_key, 12));

  RETURN jsonb_build_object('ok', true, 'agent', p_agent, 'label', trim(p_label), 'api_key', v_key);
END $$;


CREATE OR REPLACE FUNCTION revoke_api_key(p_key_prefix text) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = knowledge, public AS $$
BEGIN
  UPDATE agent_api_keys SET revoked_at = now() WHERE key_prefix = p_key_prefix AND revoked_at IS NULL;
  RETURN jsonb_build_object('ok', FOUND, 'message', CASE WHEN FOUND THEN 'Revoked.' ELSE 'No active key with that prefix.' END);
END $$;


-- Which agent a key belongs to. Unknown, revoked and empty keys all get the same answer.
CREATE OR REPLACE FUNCTION authenticate_api_key(p_key text) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = knowledge, public AS $$
DECLARE
  v_agent text;
BEGIN
  UPDATE agent_api_keys k
  SET last_used_at = now()
  FROM agents a
  WHERE a.id = k.agent_id AND k.key_hash = api_key_hash(coalesce(p_key, '')) AND k.revoked_at IS NULL
  RETURNING a.slug INTO v_agent;

  IF v_agent IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Invalid API key.');
  END IF;
  RETURN jsonb_build_object('ok', true, 'agent', v_agent);
END $$;


-- Functions are executable by everyone by default: keep key management to the owner
REVOKE EXECUTE ON FUNCTION create_api_key(text, text), revoke_api_key(text) FROM PUBLIC;
