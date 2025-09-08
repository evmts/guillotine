package history

type RotationPolicy int

const (
	KeepAll RotationPolicy = iota
	KeepLast100
	KeepLastHour
	KeepLastSession
)