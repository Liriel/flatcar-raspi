# flatcar-install/

This directory holds the `flatcar-install` script, which writes the Flatcar
OS image to a block device (SD card or USB drive).

The script is **not committed to git** (it's a third-party tool). Fetch it with:

```bash
make fetch-installer
```

or manually:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/flatcar/init/flatcar-master/bin/flatcar-install \
  -o flatcar-install/flatcar-install
chmod +x flatcar-install/flatcar-install
```

Source: https://github.com/flatcar/init/blob/flatcar-master/bin/flatcar-install
