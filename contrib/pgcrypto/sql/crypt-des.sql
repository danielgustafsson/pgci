--
-- crypt() and gen_salt(): crypt-des
--

SELECT crypt('', 'NB');

SELECT crypt('foox', 'NB');

-- We are supposed to pass in a 2-character salt.
-- error since salt is too short:
SELECT crypt('password', 'a');

CREATE TABLE ctest (data text, res text, salt text);
INSERT INTO ctest VALUES ('password', '', '');

UPDATE ctest SET salt = gen_salt('des');
UPDATE ctest SET res = crypt(data, salt);
SELECT res = crypt(data, res) AS "worked"
FROM ctest;

-- check disabling of legacy crypto functions
SET pgcrypto.legacy_crypto_enabled = off;
UPDATE ctest SET salt = gen_salt('des');
UPDATE ctest SET res = crypt(data, salt);
RESET pgcrypto.legacy_crypto_enabled;

DROP TABLE ctest;
