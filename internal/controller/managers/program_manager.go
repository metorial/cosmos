package managers

import (
	log "github.com/sirupsen/logrus"
)

type ProgramManager struct {
}

func NewProgramManager() *ProgramManager {
	return &ProgramManager{}
}

func (pm *ProgramManager) Deploy() error {
	log.Debug("Program deployment handled via agents")
	return nil
}

func (pm *ProgramManager) Remove() error {
	log.Debug("Program removal handled via agents")
	return nil
}
