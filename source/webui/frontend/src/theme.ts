import { createTheme } from "@mui/material/styles";

const borderColor = "#DDE4EE";

export const theme = createTheme({
  palette: {
    mode: "light",
    primary: {
      main: "#5267D8",
      dark: "#4052BA",
      light: "#EEF1FF",
      contrastText: "#FFFFFF"
    },
    background: {
      default: "#F6F8FB",
      paper: "#FFFFFF"
    },
    text: {
      primary: "#172033",
      secondary: "#647084"
    },
    divider: borderColor
  },
  shape: {
    borderRadius: 8
  },
  typography: {
    fontFamily:
      'Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
    h1: {
      fontSize: 28,
      fontWeight: 760,
      letterSpacing: 0
    },
    h2: {
      fontSize: 20,
      fontWeight: 760,
      letterSpacing: 0
    },
    h3: {
      fontSize: 16,
      fontWeight: 760,
      letterSpacing: 0
    },
    button: {
      fontWeight: 700,
      textTransform: "none",
      letterSpacing: 0
    }
  },
  components: {
    MuiPaper: {
      styleOverrides: {
        root: {
          backgroundImage: "none",
          border: `1px solid ${borderColor}`,
          boxShadow: "0 1px 2px rgba(23, 32, 51, 0.04)"
        }
      }
    },
    MuiButton: {
      defaultProps: {
        disableElevation: true
      },
      styleOverrides: {
        root: {
          minHeight: 36,
          borderRadius: 8
        }
      }
    },
    MuiListItemButton: {
      styleOverrides: {
        root: {
          borderRadius: 8,
          minHeight: 42,
          "&.Mui-selected": {
            backgroundColor: "#EEF1FF",
            color: "#4052BA",
            "&:hover": {
              backgroundColor: "#E5E9FF"
            }
          }
        }
      }
    },
    MuiOutlinedInput: {
      styleOverrides: {
        root: {
          backgroundColor: "#FFFFFF",
          "& fieldset": {
            borderColor
          }
        }
      }
    },
    MuiChip: {
      styleOverrides: {
        root: {
          borderRadius: 7,
          fontWeight: 700
        }
      }
    }
  }
});
