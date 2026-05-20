--! Manifest.lua — assay install pin.
--!
--! Read by `assay install` to fetch the upstream binaries + libraries
--! gondor depends on. The runtime itself (assay) is pulled separately
--! via mise; this file only covers what assay install resolves.
--!
--! Deployments may set SYSOPS_LIB_ROOT to override the install path
--! (pointing at a local sysops checkout instead of the resolved
--! tarball). When set, the pin below is documentary only.

return {
  -- Upstream libs declared by name + version. `assay install` resolves
  -- the matching tarball, verifies sha256, and extracts into the lib
  -- dir (defaults to /opt/assay/libs/<name>/). Pass that path back via
  -- SYSOPS_LIB_ROOT, or set SYSOPS_LIB_ROOT directly to a local clone.
  libs = {
    {
      name = "sysops",
      version = "0.2.0",
      -- TBD: fill in the sha256 of assay-lib-sysops-0.2.0.tar.gz once
      -- the Release libs workflow publishes the tag.
      sha256 = "TBD-sysops-0.2.0",
    },
  },
}
