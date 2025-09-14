import 'dart:convert';
import 'dart:math';

import 'package:dart_nostr/nostr/model/event/event.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mostro_mobile/core/app.dart';
import 'package:mostro_mobile/data/models/mostro_message.dart';
import 'package:mostro_mobile/data/models/nostr_event.dart';
import 'package:mostro_mobile/data/models/session.dart';
import 'package:mostro_mobile/data/models/enums/action.dart' as mostro_action;
import 'package:mostro_mobile/data/repositories/session_storage.dart';
import 'package:mostro_mobile/features/key_manager/key_derivator.dart';
import 'package:mostro_mobile/features/key_manager/key_manager.dart';
import 'package:mostro_mobile/features/key_manager/key_storage.dart';
import 'package:mostro_mobile/features/notifications/utils/notification_data_extractor.dart';
import 'package:mostro_mobile/features/notifications/utils/notification_message_mapper.dart';
import 'package:mostro_mobile/generated/l10n.dart';
import 'package:mostro_mobile/generated/l10n_en.dart';
import 'package:mostro_mobile/generated/l10n_es.dart';
import 'package:mostro_mobile/generated/l10n_it.dart';
import 'package:mostro_mobile/background/background.dart' as bg;
import 'package:mostro_mobile/shared/providers/mostro_database_provider.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

Future<void> initializeNotifications() async {
  const android = AndroidInitializationSettings('@drawable/ic_bg_service_small');
  const ios = DarwinInitializationSettings();
  const linux = LinuxInitializationSettings(defaultActionName: 'Open');
  const initSettings = InitializationSettings(android: android, iOS: ios, linux: linux, macOS: ios);
  
  await flutterLocalNotificationsPlugin.initialize(initSettings, onDidReceiveNotificationResponse: _onNotificationTap);
}

void _onNotificationTap(NotificationResponse response) {
  try {
    final context = MostroApp.navigatorKey.currentContext;
    if (context != null) {
      context.push('/notifications');
      Logger().i('Navigated to notifications screen');
    }
  } catch (e) {
    Logger().e('Navigation error: $e');
  }
}

Future<void> showLocalNotification(NostrEvent event) async {
  try {
    final mostroMessage = await _decryptAndProcessEvent(event);
    if (mostroMessage == null) return;
    

    final sessions = await _loadSessionsFromDatabase();
    final matchingSession = sessions.cast<Session?>().firstWhere(
      (session) => session?.orderId == mostroMessage.id,
      orElse: () => null,
    );
    
    final notificationData = await NotificationDataExtractor.extractFromMostroMessage(mostroMessage, null, session: matchingSession);
    if (notificationData == null || notificationData.isTemporary) return;

    final notificationText = await _getLocalizedNotificationText(notificationData.action, notificationData.values);
    final expandedText = _getExpandedText(notificationData.values);

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'mostro_channel',
        'Mostro Notifications',
        channelDescription: 'Notifications for Mostro trades and messages',
        importance: Importance.max,
        priority: Priority.high,
        visibility: NotificationVisibility.public,
        playSound: true,
        enableVibration: true,
        ticker: notificationText.title,
        icon: '@drawable/ic_notification',
        styleInformation: expandedText != null 
            ? BigTextStyleInformation(expandedText, contentTitle: notificationText.title)
            : null,
        category: AndroidNotificationCategory.message,
        autoCancel: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.critical,
        subtitle: expandedText,
      ),
    );

    await flutterLocalNotificationsPlugin.show(
      event.id.hashCode,
      notificationText.title,
      notificationText.body,
      details,
      payload: mostroMessage.id,
    );

    Logger().i('Shown: ${notificationText.title} - ${notificationText.body}');
  } catch (e) {
    Logger().e('Notification error: $e');
  }
}


Future<MostroMessage?> _decryptAndProcessEvent(NostrEvent event) async {
  try {
    if (event.kind != 4 && event.kind != 1059) return null;

    final sessions = await _loadSessionsFromDatabase();
    final matchingSession = sessions.cast<Session?>().firstWhere(
      (s) => s?.tradeKey.public == event.recipient,
      orElse: () => null,
    );

    if (matchingSession == null) return null;

    final decryptedEvent = await event.unWrap(matchingSession.tradeKey.private);
    if (decryptedEvent.content == null) return null;

    final result = jsonDecode(decryptedEvent.content!);
    if (result is! List || result.isEmpty) return null;

    final mostroMessage = MostroMessage.fromJson(result[0]);
    mostroMessage.timestamp = event.createdAt?.millisecondsSinceEpoch;
    
    return mostroMessage;
  } catch (e) {
    Logger().e('Decrypt error: $e');
    return null;
  }
}

Future<List<Session>> _loadSessionsFromDatabase() async {
  try {
    final db = await openMostroDatabase('mostro.db');
    const secureStorage = FlutterSecureStorage();
    final sharedPrefs = SharedPreferencesAsync();
    final keyStorage = KeyStorage(secureStorage: secureStorage, sharedPrefs: sharedPrefs);
    final keyDerivator = KeyDerivator("m/44'/1237'/38383'/0");
    final keyManager = KeyManager(keyStorage, keyDerivator);
    
    await keyManager.init();
    final sessionStorage = SessionStorage(keyManager, db: db);
    return await sessionStorage.getAll();
  } catch (e) {
    Logger().e('Session load error: $e');
    return [];
  }
}

class NotificationText {
  final String title;
  final String body;
  NotificationText({required this.title, required this.body});
}

Future<NotificationText> _getLocalizedNotificationText(mostro_action.Action action, Map<String, dynamic> values) async {
  try {
    final languageCode = bg.currentLanguage;
    
    final S localizations = switch (languageCode) {
      'es' => SEs(),
      'it' => SIt(),
      _ => SEn(),
    };
    
    final title = NotificationMessageMapper.getLocalizedTitleWithInstance(localizations, action);
    final body = NotificationMessageMapper.getLocalizedMessageWithInstance(localizations, action, values: values);
    
    return NotificationText(title: title, body: body);
  } catch (e) {
    final fallback = SEn();
    return NotificationText(
      title: NotificationMessageMapper.getLocalizedTitleWithInstance(fallback, action),
      body: NotificationMessageMapper.getLocalizedMessageWithInstance(fallback, action, values: values),
    );
  }
}



// Get expanded text showing additional values
String? _getExpandedText(Map<String, dynamic> values) {
  if (values.isEmpty) return null;
  
  final List<String> details = [];
  
  // Contact buyer/seller information
  if (values.containsKey('buyer_npub') && values['buyer_npub'] != null) {
    details.add('Buyer: ${values['buyer_npub']}');
  }
  
  if (values.containsKey('seller_npub') && values['seller_npub'] != null) {
    details.add('Seller: ${values['seller_npub']}');
  }
  
  // Payment information
  if (values.containsKey('fiat_amount') && values.containsKey('fiat_code')) {
    details.add('Amount: ${values['fiat_amount']} ${values['fiat_code']}');
  }
  
  if (values.containsKey('payment_method') && values['payment_method'] != null) {
    details.add('Method: ${values['payment_method']}');
  }
  
  // Expiration information
  if (values.containsKey('expiration_seconds')) {
    final seconds = values['expiration_seconds'];
    final minutes = seconds ~/ 60;
    final expiresText = _getLocalizedExpiresText();
    details.add('$expiresText: ${minutes}m ${seconds % 60}s');
  }
  
  // Lightning amount
  if (values.containsKey('amount_msat')) {
    final msat = values['amount_msat'];
    final sats = msat ~/ 1000;
    details.add('Amount: $sats sats');
  }
  
  // Payment retry information  
  if (values.containsKey('payment_attempts') && values['payment_attempts'] != null) {
    details.add('Attempts: ${values['payment_attempts']}');
  }
  
  if (values.containsKey('payment_retries_interval') && values['payment_retries_interval'] != null) {
    details.add('Retry interval: ${values['payment_retries_interval']}s');
  }
  
  // Dispute information
  if (values.containsKey('user_token') && values['user_token'] != null) {
    details.add('Token: ${values['user_token']}');
  }
  
  // Other information
  if (values.containsKey('reason')) {
    details.add('Reason: ${values['reason']}');
  }
  
  if (values.containsKey('rate')) {
    details.add('Rate: ${values['rate']}/5');
  }
  
  return details.isNotEmpty ? details.join('\n') : null;
}

// Get localized "Expires" text based on current language
String _getLocalizedExpiresText() {
  switch (bg.currentLanguage) {
    case 'es':
      return 'Expira en';
    case 'it':
      return 'Scade tra';
    case 'en':
    default:
      return 'Expires in';
  }
}

Future<void> retryNotification(NostrEvent event, {int maxAttempts = 3}) async {  
  int attempt = 0;  
  bool success = false;  
  
  while (!success && attempt < maxAttempts) {  
    try {  
      await showLocalNotification(event);  
      success = true;  
    } catch (e) {  
      attempt++;  
      if (attempt >= maxAttempts) {  
        Logger().e('Failed to show notification after $maxAttempts attempts: $e');  
        break;  
      }  
      
      // Exponential backoff: 1s, 2s, 4s, etc.  
      final backoffSeconds = pow(2, attempt - 1).toInt();  
      Logger().e('Notification attempt $attempt failed: $e. Retrying in ${backoffSeconds}s');  
      await Future.delayed(Duration(seconds: backoffSeconds));  
    }  
  }  
}  