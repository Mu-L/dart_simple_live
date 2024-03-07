import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:udp/udp.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

class TVService extends GetxService {
  static TVService get instance => Get.find<TVService>();

  UDP? udp;
  static const int udpPort = 23235;
  static const int httpPort = 23234;
  DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
  NetworkInfo networkInfo = NetworkInfo();

  HttpServer? server;

  var ipAddress = "".obs;
  var httpRunning = false.obs;
  var httpErrorMsg = "".obs;
  @override
  void onInit() {
    Log.d('TVService init');

    listenUDP();
    initServer();
    super.onInit();
  }

  /// 监听来自其他客户端的UDP广播
  /// - 如果收到广播，回复自己的信息
  void listenUDP() async {
    udp = await UDP.bind(Endpoint.any(port: const Port(udpPort)));
    udp!.asStream().listen((datagram) {
      var str = String.fromCharCodes(datagram!.data);
      Log.i("Received: $str from ${datagram.address}:${datagram.port}");
      if (str == 'Who is SimpleLiveTV?') {
        //如果http服务已经启动，就回复自己的信息
        if (httpRunning.value) {
          sendUDP();
        }
      }
    });
  }

  /// 发送自己的信息
  void sendUDP() async {
    var ip = await networkInfo.getWifiIP();

    var name = "SimpleLiveTV";
    if (Platform.isAndroid) {
      var info = await deviceInfo.androidInfo;
      name = info.device;
    } else if (Platform.isWindows) {
      var info = await deviceInfo.windowsInfo;
      name = info.userName;
    }

    var data = {
      "type": "tv",
      "name": name,
      "ip": ip ?? '',
    };

    await udp!.send(
      json.encode(data).codeUnits,
      Endpoint.broadcast(
        port: const Port(udpPort),
      ),
    );
    Log.i("send udp info: $data");
  }

  void initServer() async {
    try {
      var serverRouter = Router();
      serverRouter.get('/', _helloRequest);
      serverRouter.get('/info', _infoRequest);
      serverRouter.post('/sync/follow', _syncFollowUserReuqest);
      serverRouter.post('/sync/history', _syncHistoryReuqest);
      serverRouter.post('/sync/blocked_word', _syncBlockedWordReuqest);
      serverRouter.post('/sync/account/bilibili', _syncBiliAccountReuqest);

      var server = await shelf_io.serve(
        serverRouter,
        InternetAddress.anyIPv4,
        httpPort,
      );

      // Enable content compression
      server.autoCompress = true;

      httpRunning.value = true;

      var ip = await networkInfo.getWifiIP();
      ipAddress.value = ip ?? "";
      Log.d('Serving at http://$ip:${server.port}');
    } catch (e) {
      httpErrorMsg.value = e.toString();
      Log.logPrint(e);
    }
  }

  shelf.Response _helloRequest(shelf.Request request) {
    return toJsonResponse({
      'status': true,
      'message': 'http server is running...',
      "version": 'SimpeLiveTV v${Utils.packageInfo.version}',
    });
  }

  Future<shelf.Response> _infoRequest(shelf.Request request) async {
    var name = "SimpleLiveTV";
    if (Platform.isAndroid) {
      var info = await deviceInfo.androidInfo;
      name = info.device;
    } else if (Platform.isWindows) {
      var info = await deviceInfo.windowsInfo;
      name = info.userName;
    }
    return toJsonResponse({
      'name': name,
      'version': Utils.packageInfo.version,
      'ip': ipAddress.value,
      'port': httpPort,
    });
  }

  Future<shelf.Response> _syncFollowUserReuqest(shelf.Request request) async {
    try {
      var body = await request.readAsString();
      Log.d('_syncFollowUserReuqest: $body');
      var jsonBody = json.decode(body);
      for (var item in jsonBody) {
        var user = FollowUser.fromJson(item);
        await DBService.instance.followBox.put(user.id, user);
      }

      SmartDialog.showToast('已同步关注用户列表');
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  Future<shelf.Response> _syncHistoryReuqest(shelf.Request request) async {
    try {
      var body = await request.readAsString();
      Log.d('_syncFollowUserReuqest: $body');
      var jsonBody = json.decode(body);
      for (var item in jsonBody) {
        var history = History.fromJson(item);
        if (DBService.instance.historyBox.containsKey(history.id)) {
          var old = DBService.instance.historyBox.get(history.id);
          //如果本地的更新时间比较新，就不更新
          if (old!.updateTime.isAfter(history.updateTime)) {
            continue;
          }
        }
        await DBService.instance.addOrUpdateHistory(history);
      }

      SmartDialog.showToast('已同步观看记录');
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  Future<shelf.Response> _syncBlockedWordReuqest(shelf.Request request) async {
    try {
      var body = await request.readAsString();
      Log.d('_syncBlockedWordReuqest: $body');
      var jsonBody = json.decode(body);

      for (var keyword in jsonBody) {
        AppSettingsController.instance.addShieldList(keyword.trim());
      }
      SmartDialog.showToast('已同步弹幕屏蔽词');
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  Future<shelf.Response> _syncBiliAccountReuqest(shelf.Request request) async {
    try {
      var body = await request.readAsString();
      Log.d('_syncBiliAccountReuqest: $body');
      var jsonBody = json.decode(body);
      var cookie = jsonBody['cookie'];
      BiliBiliAccountService.instance.setCookie(cookie);
      SmartDialog.showToast('已同步哔哩哔哩账号');
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  shelf.Response toJsonResponse(Map<String, dynamic> data) {
    return shelf.Response.ok(
      json.encode(data),
      headers: {
        'Content-Type': 'application/json',
      },
      encoding: Encoding.getByName('utf-8'),
    );
  }

  @override
  void onClose() {
    Log.d('TVService close');
    udp?.close();
    server?.close(force: true);
    super.onClose();
  }
}
