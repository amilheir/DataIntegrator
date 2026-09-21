"""Custom AutoML regressor for the INMET Sao Paulo hourly station data.

Predicts TEMPERATURA_DO_AR_BULBO_SECO_HORARIA_C (dry-bulb air temperature)
from the other hourly readings.

Why HistGradientBoostingRegressor rather than the shipped candidates:

  * RADIACAO_GLOBAL_Kjm2 is EMPTY for every night-time hour - roughly half the
    file. This estimator splits on NaN natively, learning "no reading" as its
    own branch. The shipped Linear Regression cannot take NaN at all, and any
    imputer would invent a daytime-looking solar figure for midnight, which is
    worse than saying nothing.
  * The columns live on wildly different scales (pressure ~926 mB, humidity
    0-100 %, wind 0-10 m/s). A tree ensemble is scale-invariant, so no scaler
    has to be fitted or kept in sync with it.
  * At roughly 8,760 rows per station-year this trains in seconds while still
    modelling the non-linear humidity/radiation/temperature interaction that a
    linear fit flattens out.

The densify step is not optional. AutoML scores candidates through
automl_train._try_regressor(), which hands cross_validate() the feature matrix
UNTOUCHED - unlike fit_on_all_data(), it never applies fix_matrix_type. When
that matrix arrives sparse, HistGradientBoosting raises

    ValueError: A sparse matrix was passed, but dense data is required

which _try_regressor swallows as a bare ValueError and then trips over its own
`return {"mse": mse, ...}` with mse never assigned:

    UnboundLocalError: cannot access local variable 'mse'

- an error that names neither this model nor sparsity. The shipped
LinearRegression takes sparse input, so it never surfaces there. Converting
inside the pipeline keeps the fix with the model that needs it.

Registered as "inmet_temp_hgb" - that string, not the file name, is what
AutoML matches.
"""

import math

import scipy.sparse as sp
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import FunctionTransformer


def time_complexity_fn(N):
    """Cost hint AutoML uses to budget the contest. Boosted trees are the usual
    N log N, same shape as the other tree candidates."""
    return N * math.log10(N)


def _densify(X):
    """Sparse -> dense, and a no-op on anything already dense. Safe here because
    this dataset is all numeric readings: there is no high-cardinality column to
    one-hot into a matrix too wide to hold in memory."""
    return X.toarray() if sp.issparse(X) else X


class IRISModel:
    def __init__(self, **kwargs):
        self.model = Pipeline([
            ("densify", FunctionTransformer(_densify, accept_sparse=True)),
            ("hgb", HistGradientBoostingRegressor(
                # Many shallow-ish trees with a low learning rate: steadier on a
                # year of hourly weather than a few deep ones, which latch onto
                # single storm hours.
                max_iter=400,
                learning_rate=0.06,
                max_leaf_nodes=31,
                # A leaf must cover ~a day of readings before it is trusted,
                # which keeps single anomalous hours out of the fit.
                min_samples_leaf=20,
                l2_regularization=1.0,
                # Stop once a held-out slice stops improving, so max_iter above
                # is a ceiling rather than a fixed cost.
                early_stopping=True,
                validation_fraction=0.1,
                n_iter_no_change=25,
                random_state=kwargs.get('random_state', 0),
            )),
        ])
        self.name = "inmet_temp_hgb"
        self.time_complexity_fn = time_complexity_fn
        self.model_type = "Histogram Gradient Boosting"
        self.package = "sklearn"
        self.problem_type = "Regression"
