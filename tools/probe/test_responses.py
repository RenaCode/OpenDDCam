"""Tests for how the probe interprets camera responses, without a network."""

import unittest

from responses import data_dict, file_names, parse_response, play_mode


class ParseResponseTests(unittest.TestCase):
    def test_plain_object(self):
        r = parse_response(b'{"errcode":0,"data":{"a":1}}')
        self.assertEqual(r.errcode, 0)
        self.assertEqual(r.parsed["data"], {"a": 1})
        self.assertFalse(r.data_was_string)

    def test_data_as_json_string_is_unwrapped(self):
        r = parse_response(b'{"errcode":0,"data":"{\\"model\\":\\"X\\"}"}')
        self.assertEqual(r.parsed["data"], {"model": "X"})
        self.assertTrue(r.data_was_string)

    def test_data_as_non_json_string_kept(self):
        r = parse_response(b'{"errcode":0,"data":"hello"}')
        self.assertEqual(r.parsed["data"], "hello")
        self.assertFalse(r.data_was_string)

    def test_not_json(self):
        r = parse_response(b"<html>oops</html>")
        self.assertIsNone(r.parsed)
        self.assertIsNone(r.errcode)
        self.assertTrue(r.not_json)

    def test_top_level_list(self):
        r = parse_response(b"[1,2]")
        self.assertEqual(r.parsed, [1, 2])
        self.assertIsNone(r.errcode)

    def test_invalid_utf8_does_not_raise(self):
        r = parse_response(b'{"errcode":0,"data":"\xff"}')
        self.assertEqual(r.errcode, 0)


class DataDictTests(unittest.TestCase):
    def test_dict(self):
        self.assertEqual(data_dict({"data": {"x": 1}}), {"x": 1})

    def test_odd_shapes_give_empty_dict(self):
        for parsed in (None, [], "s", {"data": [1]}, {"data": "s"}, {"data": None}, {}):
            self.assertEqual(data_dict(parsed), {}, parsed)


class FileNamesTests(unittest.TestCase):
    def test_normal_listing(self):
        parsed = {"data": {"file": [{"name": "a.MP4"}, {"name": "b.MP4"}]}}
        self.assertEqual(file_names(parsed), ["a.MP4", "b.MP4"])

    def test_odd_shapes(self):
        cases = [
            None,
            {"data": [1, 2]},
            {"data": "text"},
            {"data": {"file": {"name": "a"}}},
            {"data": {"file": ["a", "b"]}},
            {"data": {"file": [{"name": None}, {"nope": 1}, {"name": 5}]}},
            {"data": {}},
        ]
        for parsed in cases:
            self.assertEqual(file_names(parsed), [], parsed)

    def test_mixed_keeps_only_valid_names(self):
        parsed = {"data": {"file": [{"name": None}, {"name": "ok.MP4"}, "x"]}}
        self.assertEqual(file_names(parsed), ["ok.MP4"])


class PlayModeTests(unittest.TestCase):
    def test_reads_playmode(self):
        self.assertEqual(play_mode({"data": {"playmode": "live"}}), "live")

    def test_missing(self):
        self.assertIsNone(play_mode({"data": {}}))
        self.assertIsNone(play_mode(None))


if __name__ == "__main__":
    unittest.main()
