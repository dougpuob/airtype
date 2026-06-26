export const compactStepperSx = {
  minWidth: { xs: 620, md: 0 },
  px: { xs: 0, md: 6 },
  py: 0.75,
  "& .MuiStepConnector-root.MuiStepConnector-alternativeLabel": {
    top: 15,
    left: "calc(-50% + 24px)",
    right: "calc(50% + 24px)"
  },
  "& .MuiStepConnector-line": {
    borderColor: "divider",
    borderTopWidth: 2
  },
  "& .MuiStepLabel-label": {
    mt: 1,
    color: "text.secondary",
    fontSize: 14,
    fontWeight: 780,
    lineHeight: 1.25
  },
  "& .MuiStepLabel-label.Mui-active, & .MuiStepLabel-label.Mui-completed": {
    color: "text.primary"
  },
  "& .MuiStepIcon-root": {
    width: 30,
    height: 30,
    color: "divider"
  },
  "& .MuiStepIcon-root.Mui-active, & .MuiStepIcon-root.Mui-completed": {
    color: "primary.main"
  },
  "& .MuiStepIcon-text": {
    fontSize: 11,
    fontWeight: 850
  }
};
