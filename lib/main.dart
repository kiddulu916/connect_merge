import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'infrastructure/ad_service.dart';
import 'infrastructure/hive_storage_service.dart';
import 'presentation/screens/tier_select_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();
  final storage = HiveStorageService();
  await storage.init();

  final adService = AdService();
  await adService.init();

  runApp(MergeLoopApp(storage: storage, adService: adService));
}

class MergeLoopApp extends StatelessWidget {
  final HiveStorageService storage;
  final AdService adService;

  const MergeLoopApp({
    super.key,
    required this.storage,
    required this.adService,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Merge Loop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: TierSelectScreen(storage: storage, adService: adService),
    );
  }
}
