// Tanuh-branded replacement for the OSS Metabase LogoIcon component.
// Replaces the inline-SVG "M" with the Tanuh PNG sitting at
// resources/frontend_client/app/assets/img/logo.png (overlaid by Dockerfile).
//
// Keep the exported signature (DefaultLogoIcon, LogoIcon, LogoIconProps) and
// the plugin-registry override path identical to upstream so anything that
// imports from this module — including the enterprise whitelabel override —
// keeps compiling.

import { PLUGIN_LOGO_ICON_COMPONENTS } from "metabase/plugins";

interface LogoIconProps {
  width?: number;
  height?: number;
  dark?: boolean;
  fill?: string;
}

export const DefaultLogoIcon = ({ height = 48, width }: LogoIconProps) => {
  return (
    <img
      src="app/assets/img/logo.png"
      width={width}
      height={height}
      alt="Tanuh"
      data-testid="main-logo"
    />
  );
};

export function LogoIcon(props: LogoIconProps) {
  const [Component = DefaultLogoIcon] = PLUGIN_LOGO_ICON_COMPONENTS;
  return <Component {...props} />;
}
