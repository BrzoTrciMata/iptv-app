# IPTV Desktop Player

Flutter desktop starter project for an IPTV player using Xtream Codes API.

## Setup

If this folder was created before Flutter desktop platform files existed, run:

```bash
flutter create --platforms=windows,macos .
flutter pub get
```

Then start the app:

```bash
flutter run -d macos
flutter run -d windows
```

The app stores the server URL and username in shared preferences, and stores the password in secure storage.
