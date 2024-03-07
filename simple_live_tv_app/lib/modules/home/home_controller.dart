import 'dart:async';

import 'package:get/get.dart';

import 'package:simple_live_tv_app/app/controller/base_controller.dart';

import 'package:simple_live_tv_app/routes/route_path.dart';

class HomeController extends BaseController {
  var datetime = "00:00".obs;

  @override
  void onInit() {
    initTimer();

    super.onInit();
  }

  void initTimer() {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      var now = DateTime.now();
      datetime.value =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    });
  }

  void toSync() {
    Get.toNamed(RoutePath.kSync);
  }

  void toFollow() {
    Get.toNamed(RoutePath.kFollow);
  }
}
