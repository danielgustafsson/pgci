-- This test exercises the JOHAB client encoding (KS X 1001:2004 Annex 3).
-- JOHAB's valid byte ranges differ from EUC-KR: trail bytes may fall within
-- the ASCII graphic range (0x41-0x7E for Hangul, 0x31-0x7E for the other
-- categories), including 0x5C which is the ASCII backslash.  Conversion to
-- SQL_ASCII verifies the source bytes without requiring a character mapping.
\pset format unaligned

-- Bug #19354 original report plus its neighbors: these three byte sequences
-- are valid Hangul syllables per Annex 3 Table 1 (lead 0x8A is in 0x84-0xD3,
-- trail 0x5B/0x5C/0x5D is in 0x41-0x7E) but were rejected by the prior
-- EUC-KR-derived check that demanded trail bytes in 0xA1-0xFE.
SELECT convert('\x8a5b', 'JOHAB', 'SQL_ASCII') AS "0x8a5b",
       convert('\x8a5c', 'JOHAB', 'SQL_ASCII') AS "0x8a5c",
       convert('\x8a5d', 'JOHAB', 'SQL_ASCII') AS "0x8a5d";

-- First multi-byte character in unicode.org's JOHAB.TXT, also rejected by
-- the prior check (trail 0x44 in Hangul range 0x41-0x7E).
SELECT convert('\x8444', 'JOHAB', 'SQL_ASCII') AS "0x8444";

-- Regression check for byte sequences that were already accepted under
-- the old rules (trail byte already within the old-allowed 0xA1-0xFE).
SELECT convert('\x89ef', 'JOHAB', 'SQL_ASCII') AS "0x89ef",
       convert('\x89a1', 'JOHAB', 'SQL_ASCII') AS "0x89a1";

-- Hangul lead and trail boundaries.
SELECT convert('\x8441', 'JOHAB', 'SQL_ASCII') AS "0x8441",
       convert('\x847e', 'JOHAB', 'SQL_ASCII') AS "0x847e",
       convert('\xd381', 'JOHAB', 'SQL_ASCII') AS "0xd381",
       convert('\xd3fe', 'JOHAB', 'SQL_ASCII') AS "0xd3fe";

-- Hanja lead and trail boundaries: leads 0xE0-0xF9 and trails 0x31-0x7E
-- or 0x91-0xFE.
SELECT convert('\xe031', 'JOHAB', 'SQL_ASCII') AS "0xe031",
       convert('\xe07e', 'JOHAB', 'SQL_ASCII') AS "0xe07e",
       convert('\xe091', 'JOHAB', 'SQL_ASCII') AS "0xe091",
       convert('\xf9fe', 'JOHAB', 'SQL_ASCII') AS "0xf9fe";

-- User-defined area A (lead 0xD8) and "Other characters" (leads 0xD9-0xDE).
SELECT convert('\xd831', 'JOHAB', 'SQL_ASCII') AS "0xd831",
       convert('\xd931', 'JOHAB', 'SQL_ASCII') AS "0xd931",
       convert('\xdefe', 'JOHAB', 'SQL_ASCII') AS "0xdefe";

-- Invalid lead bytes: the gaps between the four lead-byte ranges defined by
-- Annex 3 Table 1.
SELECT convert('\x8041', 'JOHAB', 'SQL_ASCII');
SELECT convert('\xd541', 'JOHAB', 'SQL_ASCII');
SELECT convert('\xdf41', 'JOHAB', 'SQL_ASCII');
SELECT convert('\xfa41', 'JOHAB', 'SQL_ASCII');

-- Invalid trail bytes: values inside the gaps within each trail-byte range.
-- For Hangul the gaps are 0x00-0x40, 0x7F-0x80, and 0xFF.
SELECT convert('\x8a40', 'JOHAB', 'SQL_ASCII');
SELECT convert('\x8a7f', 'JOHAB', 'SQL_ASCII');
SELECT convert('\x8a80', 'JOHAB', 'SQL_ASCII');
SELECT convert('\x8aff', 'JOHAB', 'SQL_ASCII');
-- For the other categories the gaps are 0x00-0x30, 0x7F-0x90, and 0xFF.
SELECT convert('\xe030', 'JOHAB', 'SQL_ASCII');
SELECT convert('\xe07f', 'JOHAB', 'SQL_ASCII');
SELECT convert('\xe090', 'JOHAB', 'SQL_ASCII');
SELECT convert('\xe0ff', 'JOHAB', 'SQL_ASCII');

-- Incomplete sequence: a valid lead byte with no trail byte is rejected.
SELECT convert('\x8a', 'JOHAB', 'SQL_ASCII');
