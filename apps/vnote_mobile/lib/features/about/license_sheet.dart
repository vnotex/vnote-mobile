// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> showNotebookLicenses(BuildContext context, String nativeNotices) =>
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.9,
        child: LicenseSheet(nativeNotices: nativeNotices),
      ),
    );

class LicenseSheet extends StatefulWidget {
  const LicenseSheet({required this.nativeNotices, super.key});

  final String nativeNotices;

  @override
  State<LicenseSheet> createState() => _LicenseSheetState();
}

class _LicenseSheetState extends State<LicenseSheet> {
  late final Future<List<String>> _texts = Future.wait([
    rootBundle.loadString('assets/legal/COPYING.LESSER'),
    rootBundle.loadString('assets/legal/COPYING'),
    rootBundle.loadString('assets/editor/NOTICE.txt'),
    Future.value(
      widget.nativeNotices.isEmpty
          ? 'Native library notices are available after a successful native startup.'
          : widget.nativeNotices,
    ),
  ]);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Legal notices', style: Theme.of(context).textTheme.headlineSmall),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'VNote Mobile application code is licensed under GNU LGPLv3, the same license as VNote. Bundled dependencies retain their own licenses. The full LGPL and referenced GPL terms are included below.',
          ),
        ),
        TextButton(
          onPressed: () => showLicensePage(
            context: context,
            applicationName: 'VNote Mobile',
            applicationVersion: '0.1.0',
          ),
          child: const Text('Flutter and plugin licenses'),
        ),
        Expanded(
          child: FutureBuilder<List<String>>(
            future: _texts,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return SelectableText(
                  'Legal assets could not be loaded: ${snapshot.error}',
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              const titles = [
                'GNU LGPL version 3',
                'GNU GPL version 3',
                'Bundled editor dependency notices',
                'Native core and dependency notices',
              ];
              return ListView.builder(
                itemCount: titles.length,
                itemBuilder: (context, index) => ExpansionTile(
                  title: Text(titles[index]),
                  childrenPadding: const EdgeInsets.all(8),
                  children: [SelectableText(snapshot.data![index])],
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}
