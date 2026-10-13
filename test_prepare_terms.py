import unittest

from prepare_terms import load_entries, parse_query_ids


FIXTURE = {
    "queries": [
        {
            "source_id": 1,
            "engines": {
                "tin": {
                    "conjunction": "one AND two",
                    "disjunction": "one OR two",
                    "phrase": '"one two"',
                },
                "paradedb": {"match": "one two"},
            },
        },
        {
            "source_id": 2,
            "engines": {
                "tin": {
                    "conjunction": "three AND four",
                    "disjunction": "three OR four",
                    "phrase": '"three four"',
                },
                "paradedb": {"match": "three four"},
            },
        },
    ]
}


class PrepareTermsTest(unittest.TestCase):
    def test_tin_uses_style_specific_tinql(self):
        entries = load_entries(FIXTURE, "tin", "conjunction", 1)
        self.assertCountEqual(
            entries,
            [(1, "conjunction", "one AND two"), (2, "conjunction", "three AND four")],
        )

    def test_paradedb_mixed_uses_match_text_and_keeps_styles(self):
        entries = load_entries(FIXTURE, "paradedb", "mixed", 42)
        self.assertEqual(len(entries), 6)
        self.assertCountEqual(
            [style for _, style, _ in entries],
            (
                "conjunction", "disjunction", "phrase",
                "conjunction", "disjunction", "phrase",
            ),
        )
        self.assertTrue(all(query in ("one two", "three four") for _, _, query in entries))

    def test_shuffle_is_repeatable(self):
        first = load_entries(FIXTURE, "tin", "mixed", 1592614637)
        second = load_entries(FIXTURE, "tin", "mixed", 1592614637)
        self.assertEqual(first, second)

    def test_query_id_filter(self):
        entries = load_entries(FIXTURE, "tin", "phrase", 0, "2")
        self.assertEqual(entries, [(2, "phrase", '"three four"')])

    def test_missing_query_id_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "not found"):
            load_entries(FIXTURE, "tin", "phrase", 0, "3")

    def test_duplicate_query_ids_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "distinct"):
            parse_query_ids("1,1")

    def test_flat_termset_uses_positions_as_source_ids(self):
        entries = load_entries(
            ["rust", "machine learning", "postgresql"],
            "paradedb",
            "disjunction",
            0,
        )
        self.assertCountEqual(
            entries,
            [
                (1, "disjunction", "rust"),
                (2, "disjunction", "machine learning"),
                (3, "disjunction", "postgresql"),
            ],
        )

    def test_flat_termset_supports_query_id_filter(self):
        entries = load_entries(
            ["rust", "machine learning", "postgresql"],
            "paradedb",
            "disjunction",
            0,
            "2",
        )
        self.assertEqual(entries, [(2, "disjunction", "machine learning")])

    def test_flat_termset_rejects_non_disjunction_style(self):
        with self.assertRaisesRegex(ValueError, "only support disjunction"):
            load_entries(["rust"], "paradedb", "phrase", 0)

    def test_flat_termset_rejects_empty_query(self):
        with self.assertRaisesRegex(ValueError, "nonempty string"):
            load_entries(["rust", "  "], "paradedb", "disjunction", 0)


if __name__ == "__main__":
    unittest.main()
