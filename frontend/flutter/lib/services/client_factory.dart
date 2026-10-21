import 'package:http/http.dart' as http;

import 'client_factory_stub.dart'
    if (dart.library.html) 'client_factory_web.dart' as platform;

http.Client createHeatGuardClient() => platform.createClient();
