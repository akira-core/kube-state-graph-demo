package otelinit

import (
	"os"
	"strings"

	"go.opentelemetry.io/otel/attribute"
	semconv "go.opentelemetry.io/otel/semconv/v1.27.0"
)

// defaultServiceName supplies service.name only when the environment has not
// already set it. resource.WithFromEnv reads OTEL_SERVICE_NAME and
// OTEL_RESOURCE_ATTRIBUTES; explicit WithAttributes wins over both, so the
// check has to happen here rather than by ordering the resource options.
//
// service.name is what becomes the servicegraph connector's `client` / `server`
// label, i.e. the node label users read in the panel.
func defaultServiceName(name string) []attribute.KeyValue {
	if os.Getenv("OTEL_SERVICE_NAME") != "" {
		return nil
	}
	if strings.Contains(os.Getenv("OTEL_RESOURCE_ATTRIBUTES"), "service.name=") {
		return nil
	}
	return []attribute.KeyValue{semconv.ServiceName(name)}
}
