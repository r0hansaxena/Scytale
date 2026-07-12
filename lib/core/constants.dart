import 'package:at_auth/at_auth.dart';

/// Namespace for all application data (keys look like `msg.<id>.scytale@atsign`).
const String appNamespace = 'scytale';

/// RPC domain namespace used by the Personal AI Agent.
/// Full RPC keys look like `request.<id>.agent.__rpcs.scytale@atsign`,
/// keeping agent traffic isolated from chat data.
const String agentRpcDomain = 'agent';

const String appTitle = 'Scytale';

const String starterPackUrl = 'https://my.atsign.com/starterpack_app';

/// Registrar used for the "Onboard a new Atsign" workflow.
final RegistrarService registrar = RegistrarService(
  registrarUrl: 'my.atsign.com',
  apiKey: '5f93a2fa-2e3b-4332-9924-c29cc6e164ba',
);
