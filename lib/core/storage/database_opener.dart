// Ouvre la base locale : fichier sur mobile/desktop, IndexedDB sur le web.
export 'database_opener_io.dart'
    if (dart.library.js_interop) 'database_opener_web.dart';
