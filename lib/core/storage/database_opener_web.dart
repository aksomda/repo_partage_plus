import 'package:sembast_web/sembast_web.dart';

Future<Database> openLocalDatabase() {
  return databaseFactoryWeb.openDatabase('repas_partage');
}
