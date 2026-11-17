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


class OnLinkTests(unittest.TestCase):
    """193.168.0.1 is a public address: only talk to it when our own address on
    the route to it is in the same /24, i.e. we are on the camera's Wi-Fi."""

    def test_same_subnet(self):
        from netcheck import same_subnet

        self.assertTrue(same_subnet("193.168.0.23", "193.168.0.1"))

    def test_home_network_is_not_camera(self):
        from netcheck import same_subnet

        self.assertFalse(same_subnet("192.168.3.34", "193.168.0.1"))

    def test_nearby_but_different_subnet(self):
        from netcheck import same_subnet

        self.assertFalse(same_subnet("193.168.1.5", "193.168.0.1"))

    def test_bad_input_is_false(self):
        from netcheck import same_subnet

        for src in (None, "", "not-an-ip", "::1"):
            self.assertFalse(same_subnet(src, "193.168.0.1"), src)


if __name__ == "__main__":
    unittest.main()
