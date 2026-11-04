// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';

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
    Future.value(widget.nativeNotices),
    rootBundle.loadString('assets/legal/DEPENDENCIES.txt'),
  ]);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: ListView(
      children: [
        Text(AppStrings.of(context).text('Legal notices'), style: Theme.of(context).textTheme.headlineSmall),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            AppStrings.of(context).text('VNote Mobile application code is licensed under GNU LGPLv3, the same license as VNote. Bundled dependencies retain their own licenses. The full LGPL and referenced GPL terms are included below.'),
          ),
        ),
        TextButton(
          onPressed: () => showLicensePage(
            context: context,
            applicationName: 'VNote Mobile',
            applicationVersion: '0.1.0',
          ),
          child: Text(AppStrings.of(context).text('Flutter and plugin licenses')),
        ),
        FutureBuilder<List<String>>(
            future: _texts,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return SelectableText(
                  AppStrings.of(context).text('Legal assets could not be loaded: {error}', {'error': (AppStrings.of(context).message(snapshot.error?.toString())).toString()}),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final titles = [
                AppStrings.of(context).text('GNU LGPL version 3'),
                AppStrings.of(context).text('GNU GPL version 3'),
                AppStrings.of(context).text('Bundled editor dependency notices'),
                AppStrings.of(context).text('Native core and dependency notices'),
                AppStrings.of(context).text('Dependency licenses and source notices'),
              ];
              return ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: titles.length,
                itemBuilder: (context, index) => ExpansionTile(
                  title: Text(titles[index]),
                  childrenPadding: const EdgeInsets.all(8),
                  children: [SelectableText(index == 3 && snapshot.data![index].isEmpty
                    ? AppStrings.of(context).text('Native library notices are available after a successful native startup.')
                    : snapshot.data![index])],
                ),
              );
            },
          ),
      ],
    ),
  );
}
