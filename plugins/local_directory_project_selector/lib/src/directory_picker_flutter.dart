import 'package:file_selector/file_selector.dart' as file_selector;

Future<String?> pickDirectory() => file_selector.getDirectoryPath();
