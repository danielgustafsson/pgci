-- This test exercises the JOHAB client encoding (KS X 1001:2004 Annex 3).
-- JOHAB's valid byte ranges differ from EUC-KR: trail bytes may fall within
-- the ASCII graphic range (0x41-0x7E for Hangul, 0x31-0x7E for the other
-- categories), including 0x5C which is the ASCII backslash.  The test runs
-- only in UTF8 databases, since some decoded characters have no equivalent
-- in other server encodings.
SELECT getdatabaseencoding() <> 'UTF8' AS skip_test \gset
\if :skip_test
\quit
\endif

-- Bug #19354 original report plus its neighbors: these three byte sequences
-- are valid Hangul syllables per Annex 3 Table 1 (lead 0x8A is in 0x84-0xD3,
-- trail 0x5B/0x5C/0x5D is in 0x41-0x7E) but were rejected by the prior
-- EUC-KR-derived check that demanded trail bytes in 0xA1-0xFE.
SELECT convert_from('\x8a5b'::bytea, 'johab') AS "0x8a5b",
       convert_from('\x8a5c'::bytea, 'johab') AS "0x8a5c",
       convert_from('\x8a5d'::bytea, 'johab') AS "0x8a5d";

-- First multi-byte character in unicode.org's JOHAB.TXT, also rejected by
-- the prior check (trail 0x44 in Hangul range 0x41-0x7E).
SELECT convert_from('\x8444'::bytea, 'johab') AS "0x8444";

-- Regression check for byte sequences that already decoded correctly under
-- the old rules (trail byte already within the old-allowed 0xA1-0xFE).
SELECT convert_from('\x89ef'::bytea, 'johab') AS "0x89ef",
       convert_from('\x89a1'::bytea, 'johab') AS "0x89a1";

-- Hanja range (lead 0xE0-0xF9) with trail bytes in the old-rejected region
-- 0x31-0xA0.  Per Annex 3 Table 1 the Hanja trail range is 0x31-0x7E and
-- 0x91-0xFE.
SELECT convert_from('\xe031'::bytea, 'johab') AS "0xe031",
       convert_from('\xe07e'::bytea, 'johab') AS "0xe07e",
       convert_from('\xe091'::bytea, 'johab') AS "0xe091";

-- "Other characters" category (lead 0xD9-0xDE) with a low trail byte.
SELECT convert_from('\xd931'::bytea, 'johab') AS "0xd931";

-- Invalid lead bytes: the gaps between the four lead-byte ranges defined by
-- Annex 3 Table 1.
SELECT convert_from('\x8041'::bytea, 'johab');
SELECT convert_from('\xd541'::bytea, 'johab');
SELECT convert_from('\xdf41'::bytea, 'johab');
SELECT convert_from('\xfa41'::bytea, 'johab');

-- Invalid trail bytes: values inside the gaps within each trail-byte range.
-- For Hangul the gaps are 0x00-0x40, 0x7F-0x80, and 0xFF.
SELECT convert_from('\x8a40'::bytea, 'johab');
SELECT convert_from('\x8a7f'::bytea, 'johab');
SELECT convert_from('\x8a80'::bytea, 'johab');
-- For the other categories the gaps are 0x00-0x30, 0x7F-0x90, and 0xFF.
SELECT convert_from('\xe030'::bytea, 'johab');
SELECT convert_from('\xe07f'::bytea, 'johab');
SELECT convert_from('\xe090'::bytea, 'johab');
SELECT convert_from('\xe0ff'::bytea, 'johab');

-- Incomplete sequence: a valid lead byte with no trail byte is rejected.
SELECT convert_from('\x8a'::bytea, 'johab');
