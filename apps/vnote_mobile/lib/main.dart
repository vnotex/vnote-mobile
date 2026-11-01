// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';

import 'app/editor_validation_app.dart';
import 'services/editor_session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(EditorValidationApp(session: EditorSession()));
}
