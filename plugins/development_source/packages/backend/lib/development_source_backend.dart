/// Local provider for the provisional development-source capability.
library;

export 'package:development_source_contract/development_source_contract.dart'
    show DevelopmentSourceServiceDispatcher;
export 'src/development_source_service.dart';

const String developmentSourcePluginId = 'dev.adele.plugin.development-source';
const String localDevelopmentSourceProviderId =
    'dev.adele.development-source.local';
