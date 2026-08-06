{
  description = "Zev's NixOS config — ThinkPad L480 (Intel i5-8350U, GNOME ops workstation)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs = { self, nixpkgs, nixos-hardware, ... }: {
    nixosConfigurations."l480" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/nix/configuration.nix
        nixos-hardware.nixosModules.lenovo-thinkpad
      ];
    };
  };
}
