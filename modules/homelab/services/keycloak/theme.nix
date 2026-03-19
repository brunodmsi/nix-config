{ stdenv }:
stdenv.mkDerivation rec {
  name = "keycloak_theme_bmasi";
  version = "1.0";

  src = ./themes/bmasi;

  nativeBuildInputs = [ ];
  buildInputs = [ ];

  installPhase = ''
    mkdir -p $out
    cp -a login $out
  '';
}
