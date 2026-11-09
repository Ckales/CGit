/// Code colours are chosen independently of the application appearance.
enum SyntaxTheme {
  atomOne('Atom One（默认）'),
  dracula('Dracula'),
  monokai('Monokai'),
  github('GitHub');

  const SyntaxTheme(this.label);
  final String label;

  static SyntaxTheme fromName(String? name) => values.firstWhere(
        (theme) => theme.name == name,
        orElse: () => atomOne,
      );
}
