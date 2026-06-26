export const compactStepperSx = {
  px: { xs: 0, md: 8 },
  py: 0.5,
  "& .MuiStepConnector-line": {
    borderColor: "divider"
  },
  "& .MuiStepLabel-label": {
    mt: 0.75,
    color: "text.secondary",
    fontSize: 13,
    fontWeight: 760
  },
  "& .MuiStepLabel-label.Mui-active, & .MuiStepLabel-label.Mui-completed": {
    color: "text.primary"
  },
  "& .MuiStepIcon-root": {
    width: 22,
    height: 22,
    color: "divider"
  },
  "& .MuiStepIcon-root.Mui-active, & .MuiStepIcon-root.Mui-completed": {
    color: "primary.main"
  },
  "& .MuiStepIcon-text": {
    fontSize: 12,
    fontWeight: 800
  }
};
