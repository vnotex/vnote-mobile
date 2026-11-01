// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';

import 'app/vnote_app.dart';
import 'services/notebook_session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(VNoteApp(session: NotebookSession()));
}
