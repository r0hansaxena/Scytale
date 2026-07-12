/// The four authentication workflows, modeled on the at_client_flutter
/// example app's walkthrough.dart:
///   1. Login from keychain
///   2. Onboard a new Atsign (Registrar flow)
///   3. APKAM enrollment (new device)
///   4. Login via .atKeys file
///
/// All workflows end in [_setupAtClient], which configures the
/// AtClientPreference and calls setCurrentAtSign with the already
/// authenticated atChops/atLookUp from the auth response.
library;

import 'dart:io' show Platform;

import 'package:at_auth/at_auth.dart';
import 'package:at_client_flutter/at_client_flutter.dart';
import 'package:at_utils/at_logger.dart' show AtSignLogger;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart'
    show getApplicationSupportDirectory;

import '../core/constants.dart';
import '../screens/inbox_screen.dart';
import 'call_service.dart';
import 'message_service.dart';

final AtSignLogger _logger = AtSignLogger(appNamespace);

final KeychainStorage keychainStorage = KeychainStorage();

/// Safely execute an async operation with comprehensive error logging,
/// surfacing failures to the user in a dialog.
Future<T?> safeExecute<T>(
  String operationName,
  Future<T> Function() operation, {
  BuildContext? context,
  bool showErrorDialog = true,
}) async {
  try {
    _logger.info('Starting operation: $operationName');
    final result = await operation();
    _logger.info('Completed operation: $operationName');
    return result;
  } catch (e, stackTrace) {
    _logger.severe('ERROR in $operationName: $e');
    _logger.severe('Stack trace: $stackTrace');

    if (context != null && context.mounted && showErrorDialog) {
      _showErrorDialog(context, operationName, e, stackTrace);
    }

    return null;
  }
}

void _showErrorDialog(
  BuildContext context,
  String operation,
  Object error,
  StackTrace stackTrace,
) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Error Occurred'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Operation: $operation'),
            const SizedBox(height: 8),
            Text('Error Type: ${error.runtimeType}'),
            const SizedBox(height: 8),
            const Text('Details:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(error.toString()),
            const SizedBox(height: 8),
            const Text('Stack Trace:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              stackTrace.toString(),
              style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Workflow 2: Onboard a brand-new Atsign via the Registrar.
Future<void> onboard(BuildContext context) async {
  await safeExecute('onboard', () async {
    AuthRequest? authRequest = await AtSignSelectionDialog.show(context);
    if (!context.mounted || authRequest == null) return;

    var cramKey = await RegistrarCramDialog.show(
      context,
      (authRequest as AtOnboardingRequest),
      registrar: registrar,
    );
    if (!context.mounted || cramKey == null) return;

    var response = await CramDialog.show(
      context,
      request: authRequest,
      cramKey: cramKey,
    );
    if (response == null || !response.isSuccessful) {
      _logger.warning('CramDialog failed or user cancelled');
      return;
    }

    if (!context.mounted) return;
    await _setupAtClient(context, authRequest, response);
  }, context: context);
}

/// Workflow 1: Login using an Atsign already stored in the keychain.
Future<void> loginWithKeychain(BuildContext context) async {
  await safeExecute('loginWithKeychain', () async {
    var atSigns = await keychainStorage.getAllAtsigns();
    if (atSigns.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('No Atsigns found in keychain. Please onboard first.'),
          ),
        );
      }
      return;
    }

    if (!context.mounted) return;
    AuthRequest? request =
        await AtSignSelectionDialog.show(context, existingAtSigns: atSigns);
    if (request == null || !context.mounted) return;

    var authRequest = AtAuthRequest(
      request.atSign.toAtsign(),
      atKeysIo: KeychainAtKeysIo(),
      rootDomain: request.rootDomain,
    );

    var response = await PkamDialog.show(
      context,
      request: authRequest,
      backupKeys: [KeychainAtKeysIo()],
    );
    if (response == null || !response.isSuccessful) return;

    if (!context.mounted) return;
    await _setupAtClient(context, authRequest, response);
  }, context: context);
}

/// Workflow 4: Login using a .atKeys file from the file system.
Future<void> loginWithFile(BuildContext context) async {
  await safeExecute('loginWithFile', () async {
    FileAtKeysIo? atKeysIo = await AtKeysFileDialog.show(context);
    if (atKeysIo == null || !context.mounted) return;

    // Extract the atSign from the selected filename (e.g. '@alice_key.atKeys').
    final fileName = atKeysIo.filePath!('').split(Platform.pathSeparator).last;
    var atSign = fileName.split('_key').first.toAtsign();
    _logger.info('Extracted atSign from filename: $atSign');

    var authRequest = AtAuthRequest(
      atSign,
      atKeysIo: atKeysIo,
      rootDomain: AtRootDomain.atsignDomain,
    );

    var response = await PkamDialog.show(
      context,
      request: authRequest,
      backupKeys: [KeychainAtKeysIo()],
    );
    if (response == null || !response.isSuccessful) return;

    if (!context.mounted) return;
    await _setupAtClient(context, authRequest, response);
  }, context: context);
}

/// Workflow 3: APKAM enrollment — activate this app on a new device by
/// requesting approval from an already-authorized device.
Future<void> loginWithApkam(BuildContext context) async {
  await safeExecute('loginWithApkam', () async {
    AuthRequest? request = await AtSignSelectionDialog.show(context);
    if (request == null || !context.mounted) return;

    AtEnrollmentResponse? enrollmentResponse = await ApkamActivationDialog.show(
      context,
      atSign: request.atSign.toAtsign(),
      rootDomain: request.rootDomain,
      appName: appNamespace,
      deviceName: 'linux-desktop',
      namespaces: {appNamespace: 'rw'},
    );

    if (enrollmentResponse == null) {
      throw AtAuthenticationException(
          'Enrollment failed: enrollmentResponse is null');
    }
    if (enrollmentResponse.atAuthKeys == null) {
      throw AtAuthenticationException('Enrollment failed: atAuthKeys missing');
    }

    AtAuthRequest authRequest = AtAuthRequest(
      request.atSign.toAtsign(),
      atAuthKeys: enrollmentResponse.atAuthKeys!,
      rootDomain: request.rootDomain,
    );

    if (!context.mounted) return;
    var response = await PkamDialog.show(
      context,
      request: authRequest,
      backupKeys: [KeychainAtKeysIo()],
    );
    if (response == null || !response.isSuccessful) return;

    if (!context.mounted) return;
    await _setupAtClient(context, authRequest, response);
  }, context: context);
}

/// Post-auth setup shared by all four workflows: configure the
/// AtClientPreference, initialize the AtClient with the authenticated
/// atChops/atLookUp, start the messaging service, and enter the app.
Future<void> _setupAtClient(
  BuildContext context,
  AuthRequest authRequest,
  AuthResponse response,
) async {
  var dir = await getApplicationSupportDirectory();
  _logger.info('Storage directory: ${dir.path}');

  var acp = AtClientPreference()
    ..rootDomain = authRequest.rootDomain.rootDomain
    ..rootPort = authRequest.rootDomain.rootPort
    ..namespace = appNamespace
    ..commitLogPath = dir.path
    ..hiveStoragePath = dir.path;

  // Use the atChops and atLookUp from the response: they are already
  // authenticated.
  await AtClientManager.getInstance().setCurrentAtSign(
    response.atSign.toAtsign(),
    appNamespace,
    acp,
    enrollmentId: response.enrollmentId,
    atChops: response.atChops,
    atLookUp: response.atLookUp,
  );

  await MessageService.instance.start();
  await CallService.instance.start();

  if (context.mounted) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const InboxScreen()),
    );
  }
}

/// Export the signed-in Atsign's keys from the keychain to a .atKeys file
/// (needed by the Personal AI Agent CLI, and as a backup for other devices).
Future<void> exportKeys(BuildContext context) async {
  await safeExecute('exportKeys', () async {
    final atsign =
        AtClientManager.getInstance().atClient.getCurrentAtSign()!.toAtsign();

    String? outputPath = await FilePicker.saveFile(
      dialogTitle: 'Save .atKeys file',
      fileName: '${atsign}_key.atKeys',
      type: FileType.custom,
      allowedExtensions: ['atKeys'],
    );
    if (outputPath == null) return; // user cancelled
    final path =
        outputPath.endsWith('.atKeys') ? outputPath : '$outputPath.atKeys';

    final atKeys = await keychainStorage.getAtsign(atsign);
    if (atKeys == null) {
      throw StateError('No keys found in keychain for $atsign');
    }
    await FileAtKeysIo(filePath: (_) => path).write(atsign, atKeys);

    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Keys exported to $path')));
    }
  }, context: context);
}

/// Log out: stop services and reset the AtClient.
Future<void> logout(BuildContext context) async {
  await safeExecute('logout', () async {
    await CallService.instance.stop();
    await MessageService.instance.stop();
    AtClientManager.getInstance().reset();
  }, context: context);
}
