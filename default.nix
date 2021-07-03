with import <nixpkgs> {};
haskellPackages.callCabal2nix "ocaml-export" ./. {}
