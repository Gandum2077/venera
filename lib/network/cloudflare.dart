import 'dart:io' as io;
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/utils/ext.dart';

import 'cookie_jar.dart';

class CloudflareException implements DioException {
  final String url;

  CloudflareException(this.url);

  @override
  String toString() {
    return "CloudflareException: $url";
  }

  static CloudflareException? fromString(String message) {
    var match = RegExp(r"CloudflareException: (.+)").firstMatch(message);
    if (match == null) return null;
    return CloudflareException(match.group(1)!);
  }

  @override
  DioException copyWith(
      {RequestOptions? requestOptions,
      Response<dynamic>? response,
      DioExceptionType? type,
      Object? error,
      StackTrace? stackTrace,
      String? message}) {
    return this;
  }

  @override
  Object? get error => this;

  @override
  String? get message => toString();

  @override
  RequestOptions get requestOptions => RequestOptions();

  @override
  Response? get response => null;

  @override
  StackTrace get stackTrace => StackTrace.empty;

  @override
  DioExceptionType get type => DioExceptionType.badResponse;

  @override
  DioExceptionReadableStringBuilder? stringBuilder;
}

class CloudflareInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.headers['cookie'].toString().contains('cf_clearance')) {
      options.headers['user-agent'] = appdata.implicitData['ua'] ?? webUA;
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode == 403) {
      handler.next(_check(err.response!) ?? err);
    } else {
      handler.next(err);
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (response.statusCode == 403) {
      var err = _check(response);
      if (err != null) {
        handler.reject(err);
        return;
      }
    }
    handler.next(response);
  }

  CloudflareException? _check(Response response) {
    if (response.headers['cf-mitigated']?.firstOrNull == "challenge") {
      return CloudflareException(response.requestOptions.uri.toString());
    }
    return null;
  }
}

Future<String> _resolveCurrentWebviewUrl(
  InAppWebViewController controller,
  String fallback,
) async {
  try {
    final current = await controller.getUrl();
    final value = current?.toString();
    if (value != null && value.isNotEmpty) {
      return value;
    }
  } catch (e) {
    Log.warning("Cloudflare", "Failed to resolve webview url\n$e");
  }
  return fallback;
}

Future<String> _resolveCurrentDesktopWebviewUrl(
  DesktopWebview controller,
  String fallback,
) async {
  try {
    final value = await controller.evaluateJavascript(
      "JSON.stringify(location.href)",
    );
    if (value != null) {
      final decoded = jsonDecode(value);
      if (decoded is String && decoded.isNotEmpty) {
        return decoded;
      }
    }
  } catch (e) {
    Log.warning("Cloudflare", "Failed to resolve desktop webview url\n$e");
  }
  return fallback;
}

void passCloudflare(CloudflareException e, void Function() onFinished) async {
  var url = e.url;

  void saveCookies(Uri currentUri, Map<String, String> cookies) {
    var domain = currentUri.host;
    var splits = domain.split('.');
    if (splits.length > 1) {
      domain = ".${splits[splits.length - 2]}.${splits[splits.length - 1]}";
    }
    SingleInstanceCookieJar.instance!.saveFromResponse(
      currentUri,
      List<io.Cookie>.generate(cookies.length, (index) {
        var cookie = io.Cookie(
            cookies.keys.elementAt(index), cookies.values.elementAt(index));
        cookie.domain = domain;
        return cookie;
      }),
    );
  }

  // windows version of package `flutter_inappwebview` cannot get some cookies
  // Using DesktopWebview instead
  if (App.isLinux) {
    bool finished = false;
    void complete() {
      if (finished) return;
      finished = true;
      onFinished();
    }
    var webview = DesktopWebview(
      initialUrl: url,
      onTitleChange: (title, controller) async {
        url = await _resolveCurrentDesktopWebviewUrl(controller, url);
        final currentUri = Uri.parse(url);
        var head =
            await controller.evaluateJavascript("document.head.innerHTML") ??
                "";
        var body =
            await controller.evaluateJavascript("document.body.innerHTML") ??
                "";
        Log.info("Cloudflare", "Checking head: $head");
        var isChallenging = head.contains('#challenge-success-text') ||
            head.contains("#challenge-error-text") ||
            head.contains("#challenge-form") ||
            body.contains("challenge-platform") ||
            body.contains("window._cf_chl_opt");
        if (!isChallenging) {
          Log.info(
            "Cloudflare",
            "Cloudflare is passed due to there is no challenge css",
          );
          var ua = controller.userAgent;
          if (ua != null) {
            appdata.implicitData['ua'] = ua;
            appdata.writeImplicitData();
          }
          var cookiesMap = await controller.getCookies(url);
          if (cookiesMap['cf_clearance'] == null) {
            Log.info(
              "Cloudflare",
              "cf_clearance is still missing for $url, cookies: ${cookiesMap.keys.toList()}",
            );
            return;
          }
          saveCookies(currentUri, cookiesMap);
          controller.close();
          complete();
        }
      },
      onClose: complete,
    );
    webview.open();
  } else {
    bool success = false;
    void check(InAppWebViewController controller) async {
      url = await _resolveCurrentWebviewUrl(controller, url);
      final currentUri = Uri.parse(url);
      var head = await controller.evaluateJavascript(
          source: "document.head.innerHTML") as String;
      var body = await controller.evaluateJavascript(
          source: "document.body.innerHTML") as String;
      Log.info("Cloudflare", "Checking head: $head");
      var isChallenging = head.contains('#challenge-success-text') ||
          head.contains("#challenge-error-text") ||
          head.contains("#challenge-form") ||
          body.contains("challenge-platform") ||
          body.contains("window._cf_chl_opt");
      if (!isChallenging) {
        Log.info(
          "Cloudflare",
          "Cloudflare is passed due to there is no challenge css",
        );
        var ua = await controller.getUA();
        if (ua != null) {
          appdata.implicitData['ua'] = ua;
          appdata.writeImplicitData();
        }
        var cookies = await controller.getCookies(url) ?? [];
        if (cookies.firstWhereOrNull(
                (element) => element.name == 'cf_clearance') ==
            null) {
          Log.info(
            "Cloudflare",
            "cf_clearance is still missing for $url, cookies: ${cookies.map((e) => e.name).toList()}",
          );
          return;
        }
        SingleInstanceCookieJar.instance?.saveFromResponse(currentUri, cookies);
        if (!success) {
          App.rootPop();
          success = true;
        }
      }
    }

    await App.rootContext.to(
      () => AppWebview(
        initialUrl: url,
        singlePage: true,
        onTitleChange: (title, controller) async {
          check(controller);
        },
        onLoadStop: (controller) async {
          check(controller);
        },
        onStarted: (controller) async {
          url = await _resolveCurrentWebviewUrl(controller, url);
          var ua = await controller.getUA();
          if (ua != null) {
            appdata.implicitData['ua'] = ua;
            appdata.writeImplicitData();
          }
          var cookies = await controller.getCookies(url) ?? [];
          SingleInstanceCookieJar.instance?.saveFromResponse(
            Uri.parse(url),
            cookies,
          );
        },
      ),
    );
    onFinished();
  }
}
