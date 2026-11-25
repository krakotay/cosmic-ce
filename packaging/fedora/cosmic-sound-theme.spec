Name:           cosmic-sound-theme
Version:        1.2.0
Release:        1%{?dist}
Summary:        Sound theme for the COSMIC desktop
License:        CC-BY-SA-4.0
URL:            https://github.com/pop-os/cosmic-sound-theme
Source0:        cosmic-sound-theme.tar.gz
BuildArch:      noarch
BuildRequires:  meson

%description
Default audio cues for the COSMIC desktop environment.

%prep
%autosetup -n cosmic-sound-theme

%build
%meson
%meson_build

%install
%meson_install

%files
%license LICENSE
%doc AUTHORS
%{_datadir}/sounds/COSMIC/
