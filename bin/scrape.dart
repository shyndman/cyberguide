import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart';
import 'package:quiver/iterables.dart';
import 'package:slugify/slugify.dart';
import 'package:xml/xml.dart';

final units = [
  Unit(
    id: '7A',
    bookName: 'Perspectives 7',
    description: 'Unité A, Les substances pures et les mélanges',
    type: UnitType.teacher,
  ),
  Unit(
    id: '7B',
    bookName: 'Perspectives 7',
    description: 'Unité B, Les interactions dans l’environnement',
    type: UnitType.teacher,
  ),
  Unit(
    id: '7C',
    bookName: 'Perspectives 7',
    description: 'Unité C, La chaleur dans l’environnement',
    type: UnitType.teacher,
  ),
  Unit(
    id: '7D',
    bookName: 'Perspectives 7',
    description: 'Unité D, Les structures : formes et fonctions',
    type: UnitType.teacher,
  ),
  Unit(
    id: '8A',
    bookName: 'Perspectives 8',
    description: 'Unité A, Les systèmes en action',
    type: UnitType.teacher,
  ),
  Unit(
    id: '8B',
    bookName: 'Perspectives 8',
    description: 'Unité B, La cellule',
    type: UnitType.teacher,
  ),
  Unit(
    id: '8C',
    bookName: 'Perspectives 8',
    description: 'Unité C, Les fluides',
    type: UnitType.teacher,
  ),
  Unit(
    id: '8D',
    bookName: 'Perspectives 8',
    description: 'Unité D, Les systèmes hydrographiques',
    type: UnitType.teacher,
  ),
  Unit(
    id: 'pst07',
    bookName: 'Perspectives 7',
    description: 'Science et technologie',
    type: UnitType.student,
  ),
  Unit(
    id: 'pst08',
    bookName: 'Perspectives 8',
    description: 'Science et technologie',
    type: UnitType.student,
  ),
];

enum UnitType {
  teacher,
  student,
}

class Unit {
  Unit({
    required this.id,
    required this.bookName,
    required this.description,
    required this.type,
  });

  final String id;
  final String bookName;
  final String description;
  final UnitType type;
}

const outputDirName = 'docs';

final xmlPattern = RegExp(r'^.*\.xml$', multiLine: true);

final http = HttpClient();

void main(List<String> arguments) async {
  final buildDir = Directory('./$outputDirName');
  // if (buildDir.existsSync()) {
  //   buildDir.deleteSync(recursive: true);
  // }

  // Build index

  buildDir.createSync();
  final indexFile = File('${buildDir.path}/index.html')..createSync();
  indexFile.writeAsStringSync(createRootIndex());

  // Build units

  for (final unit in units) {
    final swfUrl = Uri.parse(
        'http://www.duvaleducation.com/sciences/${unit.id}/' +
            (unit.type == UnitType.teacher
                ? 'on${unit.id.toLowerCase()}/cyberguide.swf'
                : 'student/cyberliens.swf'));

    final swfDir = dirname(swfUrl.path);
    final tempDir = Directory.systemTemp.createTempSync();

    final request = await http.getUrl(swfUrl);
    final response = await request.close();

    final swfFile = File('${tempDir.path}/${swfUrl.pathSegments.last}')
      ..createSync();
    await response.pipe(swfFile.openWrite());

    final strings = await Process.run('strings', [swfFile.absolute.path]);
    final xmlPaths = xmlPattern
        .allMatches(strings.stdout.toString())
        .map((m) => m[0]!)
        .toList();

    final xmlUrls = xmlPaths
        .map<MapEntry<String, Uri>>(
            (path) => MapEntry(path, swfUrl.replace(path: '$swfDir/$path')))
        .toMap();

    print(swfUrl);
    print(swfFile.absolute.path);
    print(xmlPaths);
    print(xmlUrls);

    final rootDocNode = await parseDocTree(unit, xmlUrls, swfUrl, swfDir);
    await writeUnitPackage(unit.id, rootDocNode);

    print('');
  }
}

String createRootIndex() {
  String unitHtml(Unit unit) {
    return '''
      <div>
        <a href="${unit.id}/index.html">
          <strong>${unit.bookName}</strong> —
          ${unit.description}
        </a>
      </div>
    ''';
  }

  return createPageHtml(
    title: 'Perspectives « Sciences « Ressources en français « Duval Éducation',
    content: '''
      <h2>Sciences — Perspectives</h2>
      <div class="teacher-units">
        <h3>Cyberguides</h3>
        ${units.where((u) => u.type == UnitType.teacher).map(unitHtml).join('\n')}
      </div>
      <div class="student-units" style="margin-top: 1rem;">
        <h3>Cyberliens</h3>
        ${units.where((u) => u.type == UnitType.student).map(unitHtml).join('\n')}
      </div>
      ''',
  );
}

Future<DocNode> parseDocTree(
  Unit unit,
  Map<String, Uri> xmlUrls,
  Uri swfUrl,
  String swfDir,
) async {
  final rootDocNodes = <DocNode>[];
  final elementsToDocNodes = <XmlElement, DocNode>{};

  final labelsDoc = await loadXmlDocument(xmlUrls['101/part1.xml']!);
  final contentDoc = await loadXmlDocument(xmlUrls['101/part2.xml']!);

  // Deliberately exclude an element that doesn't have an associated pair
  // in the label doc
  if (unit.id == 'pst08') {
    final badElements = contentDoc
        .findAllElements('level4')
        .where((e) => e.getAttribute('label') == 'Chapitre 6 Révision');
    if (badElements.isNotEmpty) {
      final badRoot = badElements.first.parentElement?.parentElement;
      badRoot?.parentElement?.children.remove(badRoot);
    }
  }

  for (final levelTag in ['level1', 'level2', 'level3']) {
    final labelLevelElements = labelsDoc.findAllElements(levelTag).toList();
    final contentLevelElements = contentDoc.findAllElements(levelTag).toList();

    if (labelLevelElements.length != contentLevelElements.length) {
      print('$levelTag: '
          '${labelLevelElements.length} != ${contentLevelElements.length}');
      throw StateError('Inequal elements');
    }

    final zippedLevelElements = zip([
      labelLevelElements,
      contentLevelElements,
    ]);

    for (final elements in zippedLevelElements) {
      final labelElement = elements[0];
      final contentElement = elements[1];

      final label = labelElement.getAttribute('label')!.replaceAll(' ', ' ');
      final docNode = elementsToDocNodes[labelElement] =
          elementsToDocNodes[contentElement] = DocNode(label);

      final parentElement = labelElement.parentElement;
      if (parentElement != null &&
          elementsToDocNodes.containsKey(parentElement)) {
        elementsToDocNodes[parentElement]!.addChild(docNode);
      }

      if (levelTag == 'level1') {
        rootDocNodes.add(docNode);
      }
    }
  }

  for (final contentTypeElement in contentDoc.findAllElements('type')) {
    final parentDocNode = elementsToDocNodes[contentTypeElement.parentElement]!;

    final typeDocNode =
        DocNode(contentTypeElement.getAttribute('label')!.replaceAll(' ', ' '));
    parentDocNode.addChild(typeDocNode);

    for (final contentElement
        in contentTypeElement.descendants.whereType<XmlElement>()) {
      final contentUrl = contentElement.getAttribute('url');
      final contentDocNode = DocNode(
        contentElement.getAttribute('label')!.replaceAll(' ', ' '),
        url: contentUrl != null
            ? swfUrl.replace(
                path: '$swfDir/${contentUrl.replaceAll(r'\', '/')}',
              )
            : null,
      );
      typeDocNode.addChild(contentDocNode);
    }
  }

  final rootDocNode = DocNode(labelsDoc.rootElement.getAttribute('label')!);
  rootDocNodes.forEach(rootDocNode.addChild);
  return rootDocNode;
}

Future<void> writeUnitPackage(String unit, DocNode rootDocNode) async {
  final unitDir = Directory('$outputDirName/$unit')..createSync(recursive: true);
  final assetsDir = Directory('${unitDir.path}/assets')..createSync();
  final indexFile = File('${unitDir.path}/index.html')..createSync();

  // Download assets
  for (final assetDocNode
      in rootDocNode.descendents.where((node) => node.hasUrl)) {
    // await downloadAsset(assetDocNode, assetsDir);
  }

  indexFile.writeAsStringSync(createDocIndex(rootDocNode));
}

String createDocIndex(DocNode rootDocNode) {
  return createPageHtml(
    title: rootDocNode.label,
    content: nodeToHtml(rootDocNode, level: 1),
  );
}

String nodeToHtml(DocNode node, {required int level}) {
  // This is an unnecessary node
  if (node.label == 'Choisissez une unité') return '';

  final sb = StringBuffer();

  if (node.hasUrl ||
      node != node.parent?.children.first ||
      node.label != node.parent?.label) {
    final headingLevel = level;

    if (1 < headingLevel && headingLevel < 5) {
      final id = Slugify(node.label);
      final idAttr = headingLevel < 5 ? ' id="$id"' : '';
      sb.writeln('''
        <h$headingLevel$idAttr>
          <a href="#$id">${node.label}</a>
        </h$headingLevel>
      ''');
    } else if (headingLevel <= 5) {
      sb.writeln('<h$headingLevel>${node.label}</h$headingLevel>');
    } else {
      final nodeContent = node.hasUrl
          ? '<a href="assets/${node.url!.pathSegments.last}">${node.label}</a>'
          : node.label;
      sb.writeln('<p>$nodeContent</p>');
    }
  }

  for (final child in node.children) {
    sb.writeln(nodeToHtml(child, level: level + 1));
  }

  return sb.toString();
}

Future<void> downloadAsset(DocNode assetDocNode, Directory assetsDir) async {
  final url = assetDocNode.url!;
  final assetFile = File('${assetsDir.path}/${url.pathSegments.last}');
  if (assetFile.existsSync()) {
    return;
  }

  stdout.write('Downloading $url');

  // Special handling for HTML files
  if (extension(url.pathSegments.last).startsWith('.htm')) {
    await Process.run(
      'wget',
      [
        '--no-host-directories',
        '--cut-dirs=${url.pathSegments.length - 1}',
        '--page-requisites',
        '--convert-links',
        '--adjust-extension',
        url.toString(),
      ],
      workingDirectory: assetsDir.path,
    );
  } else {
    final request = await http.getUrl(url);
    final response = await request.close();
    await response.pipe((assetFile..createSync()).openWrite());
  }

  stdout.writeln('  done!');
}

Future<XmlDocument> loadXmlDocument(Uri uri) async {
  final request = await http.getUrl(uri);
  final response = await request.close();

  final xmlString =
      Utf8Codec().decode((await response.toList()).flatten().toList());
  return XmlDocument.parse(xmlString);
}

String createPageHtml({required String title, required String content}) {
  return '''
  <!doctype html>
  <meta charset="utf-8">
  <html>
    <head>
      <title>$title</title>
      <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/foundation-sites@6.6.3/dist/css/foundation.min.css" integrity="sha256-ogmFxjqiTMnZhxCqVmcqTvjfe1Y/ec4WaRj/aQPvn+I=" crossorigin="anonymous">
      <style>
        html {
          padding-bottom: 3rem;
        }

        h1 > a,
        h2 > a,
        h3 > a,
        h4 > a,
        h5 > a {
          display: inline-block;
          color: #0a0a0a;
        }

        h1 > a:hover,
        h2 > a:hover,
        h3 > a:hover,
        h4 > a:hover,
        h5 > a:hover {
          color: #0a0a0a;
        }

        h1 > a:hover::after,
        h2 > a:hover::after,
        h3 > a:hover::after,
        h4 > a:hover::after,
        h5 > a:hover::after {
          display: inline-block;
          content: '';
          background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16' version='1.1' width='16' height='16' aria-hidden='true'%3E%3Cpath fill-rule='evenodd' d='M7.775 3.275a.75.75 0 001.06 1.06l1.25-1.25a2 2 0 112.83 2.83l-2.5 2.5a2 2 0 01-2.83 0 .75.75 0 00-1.06 1.06 3.5 3.5 0 004.95 0l2.5-2.5a3.5 3.5 0 00-4.95-4.95l-1.25 1.25zm-4.69 9.64a2 2 0 010-2.83l2.5-2.5a2 2 0 012.83 0 .75.75 0 001.06-1.06 3.5 3.5 0 00-4.95 0l-2.5 2.5a3.5 3.5 0 004.95 4.95l1.25-1.25a.75.75 0 00-1.06-1.06l-1.25 1.25a2 2 0 01-2.83 0z'%3E%3C/path%3E%3C/svg%3E");
          width: 16px;
          height: 16px;
          margin-left: 8px;
          vertical-align: middle;
        }

        h1 {
          font-weight: 300;
          text-align: center;
          margin-top: 3rem;
          margin-bottom: 4rem;
        }

        h2 {
          font-size: 2.3rem;
          margin-top: 1.4rem;
          margin-bottom: 0.6rem;
        }

        h3 {
          font-size: 1.8375rem;
          margin-bottom: 0.8rem;
        }

        h4 {
          font-size: 1.4625rem;
          margin-bottom: 0.3rem;
        }

        h5 {
          font-size: 1.05rem;
          font-weight: 500;
          opacity: 0.6;
          margin-top: 1rem;
          margin-bottom: 0.2rem;
        }

        p + h3 {
          margin-top: 2.2rem;
        }

        p + h4 {
          margin-top: 1.2rem;
        }

        p {
          margin-bottom: 0.2rem;
        }

        @media print, screen and (max-width: 40em) {
          h1 {
            font-size: 2rem;
            margin-top: 1.5rem;
            margin-bottom: 2rem;
          }

          h2 {
            font-size: 1.5rem;
          }

          h3 {
            font-size: 1.25rem;
          }

          h4 {
            font-size: 1.1875rem;
          }

          h5 {
            font-size: 1.126rem;
          }

          h6 {
            font-size: 1.0625rem;
          }
        }
      </style>
    </head>
    <body>
      <div class="grid-container">
        $content
      </div>
    </body>
  </html>
  ''';
}

class DocNode {
  DocNode(this.label, {this.url}) : children = [];

  final String label;
  final Uri? url;
  DocNode? parent;
  final List<DocNode> children;

  bool get hasUrl => url != null;

  Iterable<DocNode> get descendents sync* {
    for (final child in children) {
      yield child;
      yield* child.descendents;
    }
  }

  void addChild(DocNode child) {
    child.parent = this;
    children.add(child);
  }
}

extension IterableToMap<K, V> on Iterable<MapEntry<K, V>> {
  Map<K, V> toMap() => Map.fromEntries(this);
}
