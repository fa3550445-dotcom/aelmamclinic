DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
    RAISE NOTICE 'pg_trgm already installed';
  ELSIF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_trgm') THEN
    BEGIN
      CREATE EXTENSION IF NOT EXISTS pg_trgm;
      RAISE NOTICE 'pg_trgm created';
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE NOTICE 'skip pg_trgm creation: insufficient privileges';
    END;
  ELSE
    RAISE NOTICE 'pg_trgm not available on this server';
  END IF;
END$$;
