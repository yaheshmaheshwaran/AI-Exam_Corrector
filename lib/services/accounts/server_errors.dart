import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';

/// Turns whatever the college server, or the way to it, threw into a message
/// for the person at the screen: an [AccountException] for accounts, a
/// [ResultsException] for results.
///
/// The server's own rules answer with short codes (`college_not_found`,
/// `already_verified`, …); each has its sentence here, so the words live in
/// the app, in one place.
AppException describeServerError(Object error, {bool results = false}) {
  AppException fail(String message, {bool offline = false}) =>
      results ? ResultsException(message) : AccountException(message, offline: offline);

  if (error is AppException) return error;
  if (_offline(error)) {
    return fail('Can’t reach your college server. Check the internet connection, then try again.', offline: true);
  }
  if (error is AuthException) {
    if (error is AuthRetryableFetchException) {
      return fail('Can’t reach your college server. Check the internet connection, then try again.', offline: true);
    }
    // Older servers give no code, only the words.
    final String? code =
        error.code ??
        switch (error.message) {
          'Invalid login credentials' => 'invalid_credentials',
          'Email not confirmed' => 'email_not_confirmed',
          _ => null,
        };
    return fail(switch (code) {
      'invalid_credentials' => 'Wrong email, username or password.',
      'email_not_confirmed' => 'Confirm your email first — type the code that was sent to it.',
      'user_already_exists' || 'email_exists' => 'An account already uses that email. Sign in instead.',
      'weak_password' => 'Choose a stronger password — at least 8 characters.',
      'otp_expired' => 'That code has expired or is wrong. Ask for a new one.',
      'over_request_rate_limit' ||
      'over_email_send_rate_limit' => 'Too many tries in a short time. Wait a few minutes, then try again.',
      'signup_disabled' => 'Signing up is turned off on this college server.',
      'email_address_invalid' => 'The college server won’t take that email. Use one like name@college.ac.in.',
      'email_provider_disabled' =>
        'Email sign-in is turned off on this college server. Turn on the Email provider in '
            'Supabase (Authentication → Sign In / Providers → Email).',
      'session_expired' || 'refresh_token_not_found' || 'session_not_found' => 'You were signed out. Sign in again.',
      _ =>
        error.message.contains('Database error saving new user')
            ? 'The account could not be created. Check the college ID, username and roll number, then try again.'
            : 'The college server refused: ${error.message}',
    });
  }
  if (error is PostgrestException) {
    final String? known = _codes[error.message.trim()];
    if (known != null) return fail(known);
    return fail(switch (error.code) {
      '42501' => 'You don’t have permission to do that.',
      '23505' => 'That already exists.',
      'PGRST202' ||
      '42883' => 'The college server is not set up for Marklume yet. Run supabase/setup.sql on it (see the README).',
      _ => 'The college server could not do that: ${error.message}',
    });
  }
  if (error is StorageException) {
    return fail('The answer sheet pages could not be stored or fetched: ${error.message}');
  }
  return fail('Something went wrong talking to the college server: $error');
}

bool _offline(Object error) =>
    error is SocketException ||
    error is http.ClientException ||
    error is TimeoutException ||
    error is HandshakeException;

/// The server's rule codes, in words.
const Map<String, String> _codes = <String, String>{
  // Accounts.
  'college_not_found': 'No college has that college ID. Check it with your college admin.',
  'college_code_taken': 'That college ID is already registered. Choose another, or join that college as a teacher.',
  'username_taken': 'That username is taken. Try another.',
  'member_taken': 'That roll number or staff ID is already registered in this college. If it is yours, ask a teacher.',
  'too_many_attempts': 'Too many tries. Wait a few minutes, then try again.',
  'not_allowed': 'You don’t have permission to do that.',
  'not_in_college': 'That person is not in your college.',
  // Results.
  'not_found': 'That result is no longer published.',
  'already_verified': 'These marks are already verified.',
  'not_seen': 'Open and look at the result before verifying it.',
  'request_open': 'Wait for your teacher’s reply to your request before verifying.',
  'verified': 'You verified these marks, so corrections can no longer be asked for.',
  'no_such_question': 'That question is not in this result.',
  'already_requested': 'You have already asked about this question; wait for your teacher’s answer.',
  'request_not_found': 'That request no longer exists.',
  'request_answered': 'That request has already been answered.',
};
