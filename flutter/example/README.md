# lemu_analytics example

A minimal app that sets up Lemu, tracks screens with `LemuNavigatorObserver`,
and sends `AddToCart` and `Purchase`.

The platform folders are not checked in. Generate them, then run:

```bash
flutter create --platforms=android,ios,web,macos .
flutter run --dart-define=LEMU_WRITE_KEY=pk_...
```

Debug logging is on, so every call, request and response shows in the console.
