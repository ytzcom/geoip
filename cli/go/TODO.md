# Go Binary TODO

## Future Enhancements

### Add Build Date Support
The Go binary currently supports version and git commit injection via ldflags, but doesn't have a buildDate field. To add this support:

1. Add the variable to `main.go`:
```go
var (
    version   = "dev"
    buildDate = "unknown"
    gitCommit = "unknown"
)
```

2. Update the version display to include build date:
```go
fmt.Printf("geoip-updater version %s (built %s, commit %s)\n", version, buildDate, gitCommit)
```

3. The Dockerfile already passes BUILD_DATE via ldflags, so it will work once the variable is added.

This enhancement would provide better traceability for binary builds.