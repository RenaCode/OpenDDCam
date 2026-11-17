# OpenDDCam

An open-source iOS companion app for Wi-Fi dashcams built on the DDPai/Vyou
platform, including the camera that is sold as an accessory for Volvo cars.
The stock app has not been updated in years. OpenDDCam aims to replace it with a
local-only app: no account, no cloud and no telemetry.

> Status: early. The protocol is being confirmed on real hardware with the probe
> in `tools/probe`. There is no iOS app yet.

Not affiliated with or endorsed by Volvo Cars, DDPai or Peksunny. Product names
are used only to describe compatibility.

## Probe

`tools/probe/ddcam_probe.py` records how a camera answers, so the client can be
built and tested on real responses instead of guesses. It needs Python 3.9 or
newer and only the standard library.

It sends queries only, plus a normal login and logout like the stock app. It
switches the camera to live view only if the camera reports another mode. It
never changes settings, the clock, locks, recording or the memory card. The
docstring in the script lists exactly what it sends.

```sh
# laptop joined to the camera's Wi-Fi (SSID starts with volvo_ or ps_)
cd tools/probe
python3 ddcam_probe.py                              # results in ~/openddcam-probe/<timestamp>/
python3 -m unittest test_frames test_responses      # tests
```

The output contains personal data: the serial number, the login history with
phone names, recording dates and times, and possibly GPS. The probe refuses to
write it inside a git repository. Do not publish it before you scrub it.

## License

MIT, see [LICENSE](LICENSE).
