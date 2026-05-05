--! Manifest.lua — assay install pin.
--!
--! Read by `assay install` to fetch the upstream binaries + libraries
--! gondor depends on. The runtime itself (assay) is pulled separately
--! via mise; this file only covers what assay install resolves.

return {
  -- Upstream libs declared by name + version. `assay install` resolves
  -- the matching tarball from the GitHub release for that version, ver-
  -- ifies sha256, and extracts into the configured lib dir (defaults to
  -- /opt/assay/libs/<name>/). Pass that path back via SYSOPS_LIB_ROOT.
  libs = {
    { name = "sysops", version = "0.1.3" },
  },
}
