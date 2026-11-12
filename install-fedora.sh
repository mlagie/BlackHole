#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
if ! command -v dnf >/dev/null 2>&1; then
  echo 'Erreur : ce script est destine a Fedora (dnf).' >&2
  exit 1
fi

echo '[1/5] Installation de GHC, Cabal et outils de compilation...'
sudo dnf install -y ghc cabal-install gcc findutils gmp-devel zlib-devel libzstd-devel \
  shared-mime-info xdg-utils desktop-file-utils zenity

echo '[2/5] Actualisation du catalogue Hackage...'
cabal update

echo '[3/5] Compilation et tests BlackHole...'
cabal build all
cabal test all --test-show-details=direct

echo '[4/5] Installation du programme dans ~/.local/bin...'
mkdir -p "$HOME/.local/bin"
cabal install exe:blackhole --installdir="$HOME/.local/bin" --overwrite-policy=always

echo '[5/5] Association des fichiers .bh et ajout du menu contextuel...'
mkdir -p "$HOME/.config" "$HOME/.local/share/applications" \
  "$HOME/.local/share/mime/packages" "$HOME/.local/share/nautilus/scripts"
cat > "$HOME/.local/share/applications/blackhole.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=BlackHole
Comment=Extraction d'archives BlackHole
Exec="$HOME/.local/bin/blackhole" %f
Terminal=true
MimeType=application/x-blackhole;
NoDisplay=true
EOF
cat > "$HOME/.local/share/mime/packages/blackhole.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-blackhole">
    <comment>Archive BlackHole</comment>
    <glob pattern="*.bh"/>
  </mime-type>
</mime-info>
EOF
if command -v update-mime-database >/dev/null 2>&1; then
  update-mime-database "$HOME/.local/share/mime"
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$HOME/.local/share/applications"
fi
if command -v xdg-mime >/dev/null 2>&1; then
  xdg-mime default blackhole.desktop application/x-blackhole
fi
if command -v gio >/dev/null 2>&1; then
  gio mime application/x-blackhole blackhole.desktop
fi
cat > "$HOME/.local/share/nautilus/scripts/Compress with BlackHole" <<EOF
#!/usr/bin/env bash
set -euo pipefail
for item in "\$@"; do
  if ! BLACKHOLE_PROGRESS=gui "$HOME/.local/bin/blackhole" compress "\$item" 2>&1 |
      sed -u -n \
        -e 's/^Compression : \([0-9][0-9]*\) % - \(.*\) | Debit : \(.*\) | Temps restant : \(.*\)$/\1\n#Fichier : \2\n#Debit traitement : \3\n#Temps restant : \4/p' \
        -e 's/^Ecriture : \([0-9][0-9]*\) % | Debit : \(.*\) | Temps restant : \(.*\)$/\1\n#Ecriture : \2\n#Temps restant : \3/p' \
        -e 's/^Compression : \([0-9][0-9]*\) %$/\1/p' |
      zenity --progress --title='BlackHole' --text="Compression de \$item" \
        --percentage=0 --auto-close --no-cancel; then
    zenity --error --title='BlackHole' --text="La compression de \$item a echoue." || true
    exit 1
  fi
done
if command -v notify-send >/dev/null 2>&1; then
  notify-send 'BlackHole' 'Compression terminee'
fi
EOF
chmod +x "$HOME/.local/share/nautilus/scripts/Compress with BlackHole"

printf '\nInstallation terminee.\n'
printf 'Exemple : ~/.local/bin/blackhole compress examples/demo.txt -o demo.bh\n'
printf 'Double-cliquez sur une archive .bh pour l extraire automatiquement.\n'
printf 'Dans Nautilus, clic droit sur un fichier ou dossier puis Scripts > Compress with BlackHole.\n'
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  printf 'Ajoutez ~/.local/bin a votre PATH (voir README.md).\n'
fi
