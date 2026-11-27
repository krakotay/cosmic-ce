set dotenv-load
just := just_executable()
make := `which make`

build:
    mkdir -p build
    while read -r component group; do {{ just }} _build-component "$component" || exit; done < scripts/sysext-components.tsv

deb-build package:
    bash scripts/build-local-debs.sh {{quote(package)}}

install rootdir="" prefix="/usr/local": build
    while read -r component group; do {{ just }} _install-component "$component" {{quote(rootdir)}} {{quote(prefix)}} || exit; done < scripts/sysext-components.tsv

_build-component component:
    case {{quote(component)}} in \
        cosmic-icons) ;; \
        cosmic-wallpapers) {{ make }} -C cosmic-wallpapers all ;; \
        *) cd {{quote(component)}} && {{ just }} build-release ;; \
    esac

_install-component component rootdir prefix:
    case {{quote(component)}} in \
        cosmic-wallpapers) {{ make }} -C cosmic-wallpapers install DESTDIR={{quote(rootdir)}} prefix={{quote(prefix)}} ;; \
        pop-launcher) cd pop-launcher && {{ just }} rootdir={{quote(rootdir)}} install ;; \
        *) cd {{quote(component)}} && {{ just }} rootdir={{quote(rootdir)}} prefix={{quote(prefix)}} install ;; \
    esac

_mkdir dir:
   mkdir -p {{quote(dir)}}

sysext dir=(invocation_directory() / "cosmic-sysext") version=("nightly-" + `git rev-parse --short HEAD`): (_mkdir dir) (install dir "/usr")
    {{ just }} _sysext-metadata {{quote(dir)}} {{quote(version)}}

_sysext-metadata dir version=("nightly-" + `git rev-parse --short HEAD`):
    #!/usr/bin/env sh
    set -e
    mkdir -p {{quote(dir)}}/usr/lib/extension-release.d/
    cat >{{quote(dir)}}/usr/lib/extension-release.d/extension-release.cosmic-sysext <<EOF
    NAME="Cosmic DE"
    VERSION={{version}}
    $(cat /etc/os-release | grep '^ID=')
    $(cat /etc/os-release | grep '^VERSION_ID=')
    EOF
    echo "Done"

clean:
    rm -rf cosmic-sysext
    rm -rf cosmic-applets/target
    rm -rf cosmic-app-library/target
    rm -rf cosmic-bg/target
    rm -rf cosmic-comp/target
    rm -rf cosmic-edit/target
    {{ just }} cosmic-files/clean
    rm -rf cosmic-greeter/target
    {{ just }} cosmic-idle/clean
    cd cosmic-initial-setup && {{ just }} clean
    rm -rf cosmic-launcher/target
    {{ just }} cosmic-monitor/clean
    rm -rf cosmic-panel/target
    rm -rf cosmic-player/target
    rm -rf cosmic-notifications/target
    rm -rf cosmic-osd/target
    rm -rf cosmic-osk/target
    rm -rf cosmic-randr/target
    rm -rf cosmic-screenshot/target
    rm -rf cosmic-settings/target
    rm -rf cosmic-settings-daemon/target
    rm -rf cosmic-session/target
    {{ just }} cosmic-store/clean
    {{ just }} cosmic-term/clean
    {{ just }} cosmic-viewer/clean
    {{ make }} -C cosmic-wallpapers clean
    rm -rf cosmic-workspaces-epoch/target
    {{ just }} pop-launcher/clean
    rm -rf xdg-desktop-portal-cosmic/target
