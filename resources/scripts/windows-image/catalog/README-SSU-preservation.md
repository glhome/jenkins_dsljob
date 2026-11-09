# JJV Windows update manifest generator — SSU preservation update

## SSU behavior

The generator no longer searches for the newest standalone SSU automatically.

- `-BaselineManifestPath` defaults to `manifest.json` in the current working directory.
- The script copies the existing SSU dependency object from `dependencies.deps['win/updates']` into the new manifest unchanged.
- If the baseline contains KB5031539, that exact dependency (filename, artifact URL, Catalog origin URL, date, size, SHA-1 and KB) is retained.
- To replace it, pass `-RequiredSsuKb <KB>` only after prerequisite analysis confirms that the selected LCU requires that SSU. The script then looks up that exact KB in the Catalog.
- If no baseline SSU exists and no `-RequiredSsuKb` is supplied, no SSU is added automatically and a warning is printed.
- LCU and .NET Framework 4.8 selection remains tied to `-Month`.

## Example

Run from the folder containing `manifest.json`:

```powershell
.\New-JJWindowsUpdateManifest.ps1 `
  -Month 2026-10 `
  -Profile windows10-21h2 `
  -ImageUrl 'https://artifactrepo.jnj.com/artifactory/.../Windows10.iso' `
  -ImageIndex 2 `
  -AdkUrl 'https://artifactrepo.jnj.com/artifactory/.../Windows_ADK.zip' `
  -AdkVersion 'Windows_ADK_10.1.26100.2454+Update_KB5101684-JJV' `
  -ArtifactBaseUrl 'https://artifactrepo.jnj.com/artifactory/tadh-generic-snapshot' `
  -ArtifactSubPath 'third-parties/Windows10EnterpriseLTSC21H2/Updates' `
  -BaselineManifestPath '.\manifest.json' `
  -OutputPath '.\manifest-windows10-2026-10.json'
```

Only when a newer SSU is confirmed as a prerequisite:

```powershell
  -RequiredSsuKb 50xxxxxx
```

Do not pass `-RequiredSsuKb` simply because a newer SSU appears in Microsoft Update Catalog.

## Notes

- This update changes SSU selection and preserves the existing JJV dependency object.
- It does not change Microsoft Catalog `DownloadDialog.aspx` response parsing. If that endpoint continues returning error `8DDD0010`, package filename/URL metadata retrieval still needs separate diagnosis.
- The script was not executed under Windows PowerShell in this environment. Review/test it on the Windows host with the OSD module installed before using it in production.
